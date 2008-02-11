#!/usr/bin/ruby

$: << "../app"
$: << "/usr/share/ovirt-wui/app"

require 'rubygems'
require 'active_record'
require 'erb'
require 'libvirt'
require 'rexml/document'
include REXML
require 'kerberos'
include Kerberos
require 'socket'

require 'models/vm.rb'
require 'models/task.rb'
require 'models/host.rb'
require 'models/hardware_pool.rb'
require 'models/permission.rb'
require 'models/storage_volume.rb'
require 'models/quota.rb'

$stdout = File.new('/var/log/ovirt-wui/taskomatic.log', 'a')
$stderr = File.new('/var/log/ovirt-wui/taskomatic.log', 'a')

ENV['KRB5CCNAME'] = '/usr/share/ovirt-wui/ovirt-cc'

def database_configuration
  YAML::load(ERB.new(IO.read('/usr/share/ovirt-wui/config/database.yml')).result)
end

def create_vm_xml(name, uuid, memAllocated, memUsed, vcpus, bootDevice,
                  macAddr, bridge, diskDevices)
  doc = Document.new

  doc.add_element("domain", {"type" => "kvm"})
  
  doc.root.add_element("name")
  doc.root.elements["name"].text = name
  
  doc.root.add_element("uuid")
  doc.root.elements["uuid"].text = uuid
  
  doc.root.add_element("memory")
  doc.root.elements["memory"].text = memAllocated
  
  doc.root.add_element("currentMemory")
  doc.root.elements["currentMemory"].text = memUsed
  
  doc.root.add_element("vcpu")
  doc.root.elements["vcpu"].text = vcpus
  
  doc.root.add_element("os")
  doc.root.elements["os"].add_element("type")
  doc.root.elements["os"].elements["type"].text = "hvm"
  doc.root.elements["os"].add_element("boot", {"dev" => bootDevice})
  
  doc.root.add_element("clock", {"offset" => "utc"})
  
  doc.root.add_element("on_poweroff")
  doc.root.elements["on_poweroff"].text = "destroy"
  
  doc.root.add_element("on_reboot")
  doc.root.elements["on_reboot"].text = "restart"
  
  doc.root.add_element("on_crash")
  doc.root.elements["on_crash"].text = "destroy"
  
  doc.root.add_element("devices")
  doc.root.elements["devices"].add_element("emulator")
  doc.root.elements["devices"].elements["emulator"].text = "/usr/bin/qemu-kvm"

  devs = [ 'hda', 'hdb', 'hdc', 'hdd' ]
  i = 0
  diskDevices.each do |disk|
    diskdev = Element.new("disk")
    diskdev.add_attribute("type", "block")
    diskdev.add_attribute("device", "disk")
    diskdev.add_element("source", {"dev" => disk})
    diskdev.add_element("target", {"dev" => devs[i]})
    doc.root.elements["devices"] << diskdev
    i += 1
  end

  doc.root.elements["devices"].add_element("interface", {"type" => "bridge"})
  doc.root.elements["devices"].elements["interface"].add_element("mac", {"address" => macAddr})
  doc.root.elements["devices"].elements["interface"].add_element("source", {"bridge" => bridge})
  doc.root.elements["devices"].add_element("input", {"type" => "mouse", "bus" => "ps2"})
  doc.root.elements["devices"].add_element("graphics", {"type" => "vnc", "port" => "-1", "listen" => "0.0.0.0"})

  return doc
end

def setTaskState(task, state, msg = nil)
  task.state = state
  task.message = msg
  task.save
end

def setVmState(vm, state)
  vm.state = state
  vm.save
end

def findVM(task, fail_on_nil_host_id = true)
  # find the matching VM in the vms table
  vm = Vm.find(:first, :conditions => [ "id = ?", task.vm_id ])
  
  if vm == nil
    puts "No VM found"
    setTaskState(task, Task::STATE_FAILED, "VM id " + task.vm_id + "not found")
    raise
  end

  if vm.host_id == nil && fail_on_nil_host_id
    # in this case, we have no idea where the VM is.  How can we handle this
    # gracefully?  We don't necessarily want to just set the VM state to off;
    # if the machine does happen to be running somewhere and we set it to
    # disabled here, and then start it again, we could corrupt the disk

    # FIXME: the right thing to do here is probably to contact all of the
    # hosts we know about and ensure that the domain isn't running; then we
    # can mark it either as off (if we didn't find it), or mark the correct
    # vm.host_id if we did.  However, if you have a large number of hosts
    # out there, this could take a while.
    setTaskState(task, Task::STATE_FAILED, "No host_id for VM " + task.vm_id.to_s)
    raise
  end

  return vm
end

def findHost(task, vm)
  host = Host.find(:first, :conditions => [ "id = ?", vm.host_id])

  if host == nil
    # Hm, we didn't find the host_id.  Seems odd.  Return a failure

    # FIXME: we should probably contact the hosts we know about and check to
    # see if this VM is running
    setTaskState(task, Task::STATE_FAILED, "Could not find the host that VM is running on")
    raise
  end

  return host
end

# a function to find a SCSI wwid based on ipaddr, port, target, lun.  Note
# that this runs locally, so the management server will have to have access
# to the same iSCSI LUNs as the guests will
def find_wwid(ipaddr, port, target, lun)
  system('/sbin/iscsiadm --mode discovery --type sendtargets --portal ' + ipaddr)
  system('/sbin/iscsiadm --mode node --targetname ' + target + ' --portal ' + ipaddr + ':'+ port.to_s + ' --login')
  
  sessions = Dir['/sys/class/iscsi_session/session*']

  sessions.each do |session|
    current = IO.read(session + '/targetname')
    if not target <=> current
      next
    end

    # OK, we found the target; now let's go looking for the devices
    devices = Dir[session + '/device/target*/[0-9]*:' + lun.to_s]

    devices.each do |device|
      blocks = Dir[device + '/block:sd*']
      blocks.each do |block|
        out = IO.popen('/sbin/scsi_id -g -u -s ' + block.sub(/\/sys(.*)/, '\1'), mode="r")
        id = out.readline
        out.close
        return id.chomp
      end
    end
  end
  return nil
end

$dbconfig = database_configuration
$develdb = $dbconfig['development']
ActiveRecord::Base.establish_connection(
                                        :adapter  => $develdb['adapter'],
                                        :host     => $develdb['host'],
                                        :username => $develdb['username'],
                                        :password => $develdb['password'],
                                        :database => $develdb['database']
                                        )

############### TASK FUNCTIONS #######################
def create_vm(task)
  puts "create_vm"

  begin
    vm = findVM(task, false)
  rescue
    return
  end

  if vm.state != Vm::STATE_PENDING
    setTaskState(task, Task::STATE_FAILED, "VM not pending")
    return
  end

  setVmState(vm, Vm::STATE_CREATING)
  setTaskState(task, Task::STATE_RUNNING)

  # FIXME: in here, we would do any long running creating tasks (allocating
  # disk, etc.)

  setVmState(vm, Vm::STATE_STOPPED)
  setTaskState(task, Task::STATE_FINISHED)  
end

def shutdown_vm(task)
  puts "shutdown_vm"

  # here, we are given an id for a VM to shutdown; we have to lookup which
  # physical host it is running on

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_STOPPED
    # the VM is already shutdown; just return success
    setTaskState(task, Task::STATE_FINISHED)
    vm.host_id = nil
    vm.save
    return
  elsif vm.state == Vm::STATE_SUSPENDED
    setTaskState(task, Task::STATE_FAILED, "Cannot shutdown suspended domain")
    return
  elsif vm.state == Vm::STATE_SAVED
    setTaskState(task, Task::STATE_FAILED, "Cannot shutdown saved domain")
    return    
  end

  vm_orig_state = vm.state
  setVmState(vm, Vm::STATE_STOPPING)

  begin
    # OK, now that we found the VM, go looking in the hosts table
    begin
      host = findHost(task, vm)
    rescue
      raise
    end
    
    begin
      conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
      dom = conn.lookup_domain_by_uuid(vm.uuid)
      dom.shutdown
      dom.undefine
      conn.close
    rescue
      # FIXME: we could get out of sync with the host here, for instance, by the
      # user typing "shutdown" inside the guest.  That would actually shutdown
      # the guest, and the host would know about it, but we would not.  The
      # solution here is to be more selective in which exceptions we handle; a
      # connection exception we just want to fail, but if we fail to find the
      # ID on the host, we should probably still mark it shut off to regain
      # consistency
      setTaskState(task, Task::STATE_FAILED, "Error looking up domain " + vm.uuid)
      raise
    end
  rescue
    setVmState(vm, vm_orig_state)
  end

  setTaskState(task, Task::STATE_FINISHED)

  vm.host_id = nil
  vm.memory_used = nil
  vm.num_vcpus_used = nil
  vm.state = Vm::STATE_STOPPED
  vm.needs_restart = nil
  vm.save
end

def start_vm(task)
  puts "start_vm"

  # here, we are given an id for a VM to start

  begin
    vm = findVM(task, false)
  rescue
    return
  end

  if vm.state == Vm::STATE_RUNNING
    # the VM is already running; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_SUSPENDED
    setTaskState(task, Task::STATE_FAILED, "Cannot start suspended domain")
    return
  elsif vm.state == Vm::STATE_SAVED
    setTaskState(task, Task::STATE_FAILED, "Cannot start saved domain")
    return
  end

  # FIXME: Validate that the VM is still within quota
  #vm.validate

  vm_orig_state = vm.state
  setVmState(vm, Vm::STATE_STARTING)

  # FIXME: the VM might be in an inconsistent state in the database; however, we
  # should check it out on the remote host, and update the database as
  # appropriate

  begin
    if vm.host_id != nil
      # OK, marked in the database as already running on a host; for now, we
      # will just fail the operation
      
      # FIXME: we probably want to go out to the host it is marked on and check
      # things out, just to make sure things are consistent
      errmsg = "VM already running"      
      raise
    end
    
    # OK, now that we found the VM, go looking in the hardware_pool
    # hosts to see if there is a host that will fit these constraints
    host = nil
    vm.quota.hardware_pool.hosts.each do |curr|
      if curr.num_cpus >= vm.num_vcpus_allocated and curr.memory >= vm.memory_allocated
        host = curr
        break
      end
    end
    
    if host == nil
      # we couldn't find a host that matches this description; report ERROR
      errmsg = "No host matching VM parameters could be found"
      raise
    end

    storagedevs = []
    vm.storage_volumes.each do |volume|
      wwid = find_wwid(volume.ip_addr, volume.port, volume.target, volume.lun)

      if wwid != nil
        storagedevs << "/dev/disk/by-id/scsi-" + wwid
      end
    end
 
    if storagedevs.length < 1
      # we couldn't find *any* disk to attach to the VM; we have to quit
      # FIXME: eventually, we probably want to allow diskless machines that will
      # boot via NFS or iSCSI or whatever
      errmsg = "No valid storage volumes found"
      raise
    elsif storagedevs.length > 4
      errmsg = "Too many storage volumes; maximum is 4"
      raise
    end

    # OK, we found a host that will work; now let's build up the XML
    
    # FIXME: get rid of the hardcoded bridge
    xml = create_vm_xml(vm.description, vm.uuid, vm.memory_allocated,
                        vm.memory_used, vm.num_vcpus_allocated, vm.boot_device,
                        vm.vnic_mac_addr, "ovirtbr0", storagedevs)

    begin
      conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
      dom = conn.define_domain_xml(xml.to_s)
      dom.create
      conn.close
    rescue
      # FIXME: these may fail for various reasons:
      # 1.  The domain is already defined and/or started - update the DB
      # 2.  We couldn't define the domain for some reason
      errmsg = "Libvirt error"
      raise
    end
  rescue
    setTaskState(task, Task::STATE_FAILED, errmsg)
    setVmState(vm, vm_orig_state)
    return
  end

  setTaskState(task, Task::STATE_FINISHED)

  vm.host_id = host.id
  vm.state = Vm::STATE_RUNNING
  vm.memory_used = vm.memory_allocated
  vm.num_vcpus_used = vm.num_vcpus_allocated
  vm.boot_device = Vm::BOOT_DEV_HD
  vm.save
end

def save_vm(task)
  puts "save_vm"

  # here, we are given an id for a VM to suspend

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_SAVED
    # the VM is already saved; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_SUSPENDED
    setTaskState(task, Task::STATE_FAILED, "Cannot save suspended domain")
    return    
  elsif vm.state == Vm::STATE_STOPPED
    setTaskState(task, Task::STATE_FAILED, "Cannot save shutdown domain")
    return
  end

  vm_orig_state = vm.state
  setVmState(vm, Vm::STATE_SAVING)

  begin
    # OK, now that we found the VM, go looking in the hosts table
    begin
      host = findHost(task, vm)
    rescue
      raise
    end
    
    begin
      conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
      dom = conn.lookup_domain_by_uuid(vm.uuid)
      dom.save("/tmp/" + vm.uuid + ".save")
      conn.close
    rescue
      setTaskState(task, Task::STATE_FAILED, "Save failed")
      raise
    end
  rescue
    setVmState(vm, vm_orig_state)
    return
  end

  # note that we do *not* reset the host_id here, since we stored the saved
  # vm state information locally.  restore_vm will pick it up from here

  # FIXME: it would be much nicer to be able to save the VM and remove the
  # the host_id and undefine the XML; that way we could resume it on another
  # host later.  This can be done once we have the storage APIs, but it will
  # need more work

  setTaskState(task, Task::STATE_FINISHED)

  vm.state = Vm::STATE_SAVED
  vm.save
end

def restore_vm(task)
  puts "restore_vm"

  # here, we are given an id for a VM to start

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_RUNNING
    # the VM is already saved; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_SUSPENDED
    setTaskState(task, Task::STATE_FAILED, "Cannot restore suspended domain")
    return    
  elsif vm.state == Vm::STATE_STOPPED
    setTaskState(task, Task::STATE_FAILED, "Cannot restore shutdown domain")
    return
  end

  vm_orig_state = vm.state
  setVmState(vm, Vm::STATE_RESTORING)

  begin
    # OK, now that we found the VM, go looking in the hosts table
    begin
      host = findHost(task, vm)
    rescue
      raise
    end
    
    # FIXME: we should probably go out to the host and check what it thinks
    # the state is
    
    begin
      conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
      dom = conn.lookup_domain_by_uuid(vm.uuid)
      dom.restore
      conn.close
    rescue
      # FIXME: these may fail for various reasons:
      # 1.  The domain is already defined and/or started - update the DB
      # 2.  We couldn't define the domain for some reason
      setTaskState(task, Task::STATE_FAILED, "Libvirt error")
      raise
    end
  rescue
    setVmState(vm, vm_orig_state)
    return
  end

  setTaskState(task, Task::STATE_FINISHED)

  vm.state = Vm::STATE_RUNNING
  vm.save
end

def suspend_vm(task)
  puts "suspend_vm"

  # here, we are given an id for a VM to suspend; we have to lookup which
  # physical host it is running on

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_SUSPENDED
    # the VM is already suspended; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_STOPPED
    setTaskState(task, Task::STATE_FAILED, "Cannot suspend stopped domain")
    return
  elsif vm.state == Vm::STATE_SAVED
    setTaskState(task, Task::STATE_FAILED, "Cannot suspend saved domain")
    return
  end

  vm_orig_state = vm.state
  setVmState(vm, Vm::STATE_SUSPENDING)

  begin
    # OK, now that we found the VM, go looking in the hosts table
    begin
      host = findHost(task, vm)
    rescue
      raise
    end
    
    begin
      conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
      dom = conn.lookup_domain_by_uuid(vm.uuid)
      dom.suspend
      conn.close
    rescue
      setTaskState(task, Task::STATE_FAILED, "Error looking up domain " + vm.uuid)
      raise
    end
  rescue
    setVmState(vm, vm_orig_state)
    return
  end

  # note that we do *not* reset the host_id here, since we just suspended the VM
  # resume_vm will pick it up from here

  setTaskState(task, Task::STATE_FINISHED)

  vm.state = Vm::STATE_SUSPENDED
  vm.save
end

def resume_vm(task)
  puts "resume_vm"

  # here, we are given an id for a VM to start

  begin
    vm = findVM(task)
  rescue
    return
  end

  # OK, marked in the database as already running on a host; let's check it

  if vm.state == Vm::STATE_RUNNING
    # the VM is already suspended; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_STOPPED
    setTaskState(task, Task::STATE_FAILED, "Cannot resume stopped domain")
    return
  elsif vm.state == Vm::STATE_SAVED
    setTaskState(task, Task::STATE_FAILED, "Cannot resume suspended domain")
    return
  end

  vm_orig_state = vm.state
  setVmState(vm, Vm::STATE_RESUMING)

  begin
    # OK, now that we found the VM, go looking in the hosts table
    begin
      host = findHost(task, vm)
    rescue
      raise
    end
    
    begin
      conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
      dom = conn.lookup_domain_by_uuid(vm.uuid)
      dom.resume
      conn.close
    rescue
      setTaskState(task, Task::STATE_FAILED, "Error looking up domain " + vm.uuid)
      raise
    end
  rescue
    setVmState(vm, vm_orig_state)
    return
  end

  setTaskState(task, Task::STATE_FINISHED)
  
  vm.state = Vm::STATE_RUNNING
  vm.save
end

pid = fork do
  loop do
    puts 'Checking for tasks...'

    # make sure we get our credentials up-front
    krb5 = Krb5.new
    default_realm = krb5.get_default_realm
    krb5.get_init_creds_keytab('libvirt/' + Socket::gethostname + '@' + default_realm, '/usr/share/ovirt-wui/ovirt.keytab')
    krb5.cache(ENV['KRB5CCNAME'])

    Task.find(:all, :conditions => [ "state = ?", Task::STATE_QUEUED ]).each do |task|
      case task.action
      when Task::ACTION_CREATE_VM then create_vm(task)
      when Task::ACTION_SHUTDOWN_VM then shutdown_vm(task)
      when Task::ACTION_START_VM then start_vm(task)
      when Task::ACTION_SUSPEND_VM then suspend_vm(task)
      when Task::ACTION_RESUME_VM then resume_vm(task)
      when Task::ACTION_SAVE_VM then save_vm(task)
      when Task::ACTION_RESTORE_VM then restore_vm(task)
      else
        puts "unknown task " + task.action
        setTaskState(task, Task::STATE_FAILED, "Unknown task type")
      end
      
      task.time_ended = Time.now
      task.save
    end
    
    # we could destroy credentials, but another process might be using them (in
    # particular, host-browser).  Just leave them around, it shouldn't hurt

    $stdout.flush
    sleep 5
  end
end

Process.detach(pid)
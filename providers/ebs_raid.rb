include Opscode::Aws::Ec2

action :auto_attach do

  # Baseline expectations.
  node.set['aws'] ||= {}
  node.set[:aws][:raid] ||= {}

  # Mount point information.
  node.set[:aws][:raid][@new_resource.mount_point] ||= {}

  if already_mounted(@new_resource.mount_point)
    update_node_from_md_device(md_device_from_mount_point(@new_resource.mount_point), @new_resource.mount_point)
  else
    creating_from_snapshot = !(@new_resource.snapshots.nil? || @new_resource.snapshots.size == 0)
    use_existing_volumes = !(@new_resource.existing_volumes.nil? || @new_resource.existing_volumes.size == 0)

    devices = attach_ebs_volumes(@new_resource.disk_count,
                                 @new_resource.disk_size,
                                 @new_resource.snapshots,
                                 @new_resource.disk_type,
                                 @new_resource.disk_piops,
                                 @new_resource.existing_volumes,
                                 @new_resource.mount_point,
                                 creating_from_snapshot,
                                 use_existing_volumes,
                                 @new_resource.aws_access_key,
                                 @new_resource.aws_secret_access_key)

    create_raid_disk(@new_resource.mount_point,
                     @new_resource.filesystem,
                     @new_resource.filesystem_options,
                     @new_resource.level,
                     creating_from_snapshot,
                     devices)

    @new_resource.updated_by_last_action(true)
  end

end

private

def already_mounted(mount_point)
  if !::File.exists?(mount_point)
    return false
  end

  md_device = md_device_from_mount_point(mount_point)
  if !md_device || md_device == ''
    return false
  end

  true
end

def attach_ebs_volumes(disk_count,
    disk_size,
    snapshots,
    disk_type,
    disk_piops,
    existing_volumes,
    mount_point,
    creating_from_snapshot,
    use_existing_volumes,
    aws_access_key,
    aws_secret_access_key)

  disk_dev = find_free_volume_device_prefix
  Chef::Log.debug("vol device prefix is #{disk_dev}")

  devices = {}

  if use_existing_volumes
    disk_count = existing_volumes.size
    (1..disk_count).each do |i|

      disk_dev_path = "#{disk_dev}#{i}"

      volume = existing_volumes[i - 1]
      Chef::Log.info("attach dev: #{disk_dev_path} existing volume #{volume}")
      attach_volume(volume, instance_id, "/dev/#{disk_dev_path}", 10*60)
      node.set['aws']['ebs_volume'][disk_dev_path]['volume_id'] = volume
      node.save
      devices[disk_dev_path] = {}
      devices[disk_dev_path]['aws_volume_id'] = node['aws']['ebs_volume'][disk_dev_path]['volume_id']
      devices[disk_dev_path]['aws_device_id'] = "/dev/#{disk_dev_path}"
      devices[disk_dev_path]['os_device_id'] = "/dev/#{os_dev_path_for(disk_dev_path)}"
    end
  else
    (1..disk_count).each do |i|

      disk_dev_path = "#{disk_dev}#{i}"

      Chef::Log.info("creating ebs volume for device #{disk_dev_path} with size #{disk_size}")
      nvid = create_volume(creating_from_snapshot ? snapshots[i-1] : '',
                           disk_size,
                           nil,
                           15*60,
                           disk_type,
                           disk_piops)
      attach_volume(nvid, instance_id, "/dev/#{disk_dev_path}", 15*60)
      node.set['aws']['ebs_volume'][disk_dev_path]['volume_id'] = nvid
      node.save

      devices[disk_dev_path] = {}
      devices[disk_dev_path]['aws_volume_id'] = node['aws']['ebs_volume'][disk_dev_path]['volume_id']
      devices[disk_dev_path]['aws_device_id'] = "/dev/#{disk_dev_path}"
      devices[disk_dev_path]['os_device_id'] = "/dev/#{os_dev_path_for(disk_dev_path)}"
    end
  end
  node.set[:aws][:raid][mount_point][:device_attach_delay] = wait_for_mounted_volumes(devices)
  Chef::Log.info("attached devices #{devices}")
  devices
end

def create_raid_disk(mount_point, filesystem, filesystem_options, level, creating_from_snapshot, devices)
  devices_string = device_map_to_string(devices)
  Chef::Log.info("Adding #{devices_string} to new raid array")

  raid_dev = find_free_md_device_name
  Chef::Log.debug("target raid device is #{raid_dev}")

  if not creating_from_snapshot
    # Create the raid device on our system
    Chef::Log.info("creating raid device /dev/#{raid_dev} with raid devices #{devices_string}")
    o = `mdadm --create /dev/#{raid_dev} --level=#{level} --raid-devices=#{devices.size} #{devices_string}`
    e = $?
    raise "Failed to create raid array: #{o}" if e.to_i != 0

    # For some silly reason we can't call the function.
    raid_dev = find_md_device(devices)

    Chef::Log.info("Format device found: /dev/#{raid_dev}")
    case filesystem
      when "ext4"
        Chef::Log.info("Creating ext4 filesystem on: /dev/#{raid_dev}")

        count = 0
        ret_value = 99
        test_uuid = ''
        until (ret_value == 0 && test_uuid.to_s != '') || count > 10 do
          o1 = `mke2fs -t #{filesystem} -F /dev/#{raid_dev}`
          ret_value = $?.to_i
          test_uuid = get_device_uuid(raid_dev)
          if ret_value != 0 || test_uuid.to_s == ''
            Chef::Log.warn("Dev file system not successfully created.  Sleeping 120 and trying again")
            sleep 120
            count += 1
          end
          test_uuid = get_device_uuid(raid_dev)
        end

        raise "Failed to create file system ext4: #{o1}" if ret_value != 0
      else
        #TODO fill in details on how to format other filesystems here
        Chef::Log.info("Can't format filesystem #{filesystem}")
    end
  else
    # Reassembling the raid device on our system
    assemble_raid(raid_dev, devices_string)
    raid_dev = find_md_device(devices)
  end

  mount_device(raid_dev, mount_point, filesystem, filesystem_options)

  `update-initramfs -u`

  update_node_from_md_device(raid_dev, mount_point)
end

def os_dev_path_for(device)
  if device.start_with?('sd')
    'xvd' + device[2..-1]
  else
    device
  end
end

# AWS's volume attachment interface assumes that we're using
# sdX style device names.  The ones we actually get will be xvdX
def find_free_volume_device_prefix
  # Specific to ubuntu 11./12.
  vol_dev = "sdh"

  begin
    vol_dev = vol_dev.next
    base_device = "/dev/#{os_dev_path_for(vol_dev)}1"
    Chef::Log.info("dev pre trim #{base_device}")
  end while ::File.exists?(base_device)

  vol_dev
end

def find_free_md_device_name
  number=0
  #TODO, this won't work with more than 10 md devices
  begin
    dir = "/dev/md#{number}"
    Chef::Log.info("md pre trim #{dir}")
    number +=1
  end while ::File.exists?(dir)

  dir[5, dir.length]
end

def md_device_from_mount_point(mount_point)
  md_device = ""
  Dir.glob("/dev/md[0-9]*").each do |dir|
    # Look at the mount point directory and see if containing device
    # is the same as the md device.
    if ::File.lstat(dir).rdev == ::File.lstat(mount_point).dev
      md_device = dir[5, dir.length]
      break
    end
  end
  md_device
end

def get_device_uuid(md_device)
  puts `ls -l /dev/disk/by-uuid`
  command = "ls -l /dev/disk/by-uuid | grep '#{md_device}' | awk '{print $9}' | tr -d '\\n'"
  Chef::Log.info("Running #{command}")
  raid_uuid = `#{command}`
  Chef::Log.info("Raid device UUID: #{raid_uuid}")
  raid_uuid
end

def get_devices_from_md_device(md_device)
  command = "mdadm --misc -D /dev/#{md_device} | grep '/dev/xvd' | awk '{print $7}' | tr '\\n' ' '"
  Chef::Log.info("Running #{command}")
  raid_devices = `#{command}`.split(' ')
  Chef::Log.info("already found the mounted device, created from #{raid_devices}")
  raid_devices
end

def does_md_device_contain(md_device, device)
  command = "mdadm --misc -D #{md_device} | grep '#{device}' | wc -l | tr -d '\\n'"
  Chef::Log.info("Running #{command}")
  count = `#{command}`
  Chef::Log.info("count #{count}")
  count.to_i == 1
end

def update_node_from_md_device(md_device, mount_point)
  data = get_md_device_data_for(md_device)

  node.set[:aws][:raid][mount_point][:raid_dev] = md_device
  node.set[:aws][:raid][mount_point][:devices] = data['raid_devices']
  node.set[:aws][:raid][mount_point][:uuid] = data['raid_uuid']
  node.save
end

def get_md_device_data_for(md_device)
  data = {}
  if md_device && md_device != ''
    data['raid_devices'] = get_devices_from_md_device(md_device)
    data['raid_uuid'] = get_device_uuid(md_device)
    data['raid_dev'] = md_device.sub(/\/dev\//, '')
  end
  data
end

def get_md_device_data(mount_point, raid_devices)
  md_device = md_device_from_mount_point(mount_point)
  if !md_device || md_device == ''
    Dir.glob('/dev/md[0-9]*').each do |dir|
      if does_md_device_contain(dir, raid_devices[0])
        md_device = dir
        break
      end
    end
  end
  get_md_device_data_for(md_device)
end

# Dumb way to look for mounted raid devices.  Assumes that the machine
# will only create one.
def find_md_device(raid_devices)
  md_device = nil
  Dir.glob('/dev/md[0-9]*').each do |dir|
    if does_md_device_contain(dir, raid_devices.values[0]['os_device_id'])
      md_device = dir[5, dir.length]
      break
    end
  end
  md_device
end

# Generate the string using the corrected map.
def device_map_to_string(device_map)
  devices_string = ''
  device_map.keys.sort.each do |k|
    devices_string += "#{device_map[k]['os_device_id']} "
  end
  devices_string
end

def wait_for_mounted_volumes(device_vol_map)
  # Wait until all volumes are mounted
  count = 0
  until device_vol_map.all? { |vol| ::File.exists?("#{vol[1]['os_device_id']}") } do
    Chef::Log.info("sleeping 10 seconds until EBS volumes have re-attached (#{device_vol_map})")
    sleep 10
    count += 1
  end
  count * 10
end

# Assembles the raid if it doesn't already exist
# Note: raid_dev is the "suggested" location.  mdadm may actually put it somewhere else.
def assemble_raid(raid_dev, devices_string)
  if ::File.exists?(raid_dev)
    Chef::Log.info("Device /dev/#{raid_dev} exists skipping")
    return
  end

  Chef::Log.info("Raid device /dev/#{raid_dev} does not exist re-assembling")
  Chef::Log.debug("Devices for /dev/#{raid_dev} are #{devices_string}")

  # Now that attach is done we re-build the md device
  o = `mdadm --assemble /dev/#{raid_dev} #{devices_string}`
  e = $?
  raise "Failed to assemble raid array: #{o}" if e.to_i != 0 || e.to_i != 2
end

def attempt_mount(raid_dev, mount_point, filesystem_options, filesystem)
  device_uuid = nil

  `test -d #{mount_point}`
  if $?.to_i != 0
    `mkdir -p #{mount_point}`
  end

  count = 0
  ret_value = 99
  until ret_value == 0 || count > 60 do
    device_uuid = get_device_uuid(raid_dev)
    o = `mount -t #{filesystem} -o "#{filesystem_options}" -U #{device_uuid} #{mount_point}`
    ret_value = $?.to_i
    if ret_value != 0
      Chef::Log.warn("Mount for #{mount_point} UUID=#{device_uuid} failed (#{o}).  Sleeping 10 and trying again")
      sleep 10
      count += 1
    end
  end
  raise "Failed to mount drive: #{mount_point}:#{o}" if ret_value != 0
  device_uuid
end

def mount_device(raid_dev, mount_point, filesystem, filesystem_options)
  device_uuid = attempt_mount(raid_dev, mount_point, filesystem_options, filesystem)

  mount mount_point do
    fstype filesystem
    device_type :uuid
    device device_uuid
    options filesystem_options
    action [:enable]
  end
end

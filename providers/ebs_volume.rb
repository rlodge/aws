include Opscode::Aws::Ec2

# Support whyrun
def whyrun_supported?
  true
end

action :create do
  raise "Cannot create a volume with a specific id (EC2 chooses volume ids)" if new_resource.volume_id
  if new_resource.snapshot_id =~ /vol/
    new_resource.snapshot_id(find_snapshot_id(new_resource.snapshot_id, new_resource.most_recent_snapshot))
  end

  nvid = volume_id_in_node_data
  if nvid
    # volume id is registered in the node data, so check that the volume in fact exists in EC2
    vol = volume_by_id(nvid)
    exists = vol && vol[:aws_status] != "deleting"
    # TODO: determine whether this should be an error or just cause a new volume to be created. Currently erring on the side of failing loudly
    raise "Volume with id #{nvid} is registered with the node but does not exist in EC2. To clear this error, remove the ['aws']['ebs_volume']['#{new_resource.name}']['volume_id'] entry from this node's data." unless exists
  else
    # Determine if there is a volume that meets the resource's specifications and is attached to the current
    # instance in case a previous [:create, :attach] run created and attached a volume but for some reason was
    # not registered in the node data (e.g. an exception is thrown after the attach_volume request was accepted
    # by EC2, causing the node data to not be stored on the server)
    if new_resource.device && (attached_volume = currently_attached_volume(instance_id, new_resource.device))
      Chef::Log.debug("There is already a volume attached at device #{new_resource.device}")
      compatible = volume_compatible_with_resource_definition?(attached_volume)
      raise "Volume #{attached_volume[:aws_id]} attached at #{attached_volume[:aws_device]} but does not conform to this resource's specifications" unless compatible
      Chef::Log.debug("The volume matches the resource's definition, so the volume is assumed to be already created")
      converge_by("update the node data with volume id: #{attached_volume[:aws_id]}") do
        node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = attached_volume[:aws_id]
        node.save unless Chef::Config[:solo]
      end
    else
      # If not, create volume and register its id in the node data
      converge_by("create a volume with id=#{new_resource.snapshot_id} size=#{new_resource.size} availability_zone=#{new_resource.availability_zone} and update the node data with created volume's id") do
      nvid = create_volume(new_resource.snapshot_id,
                           new_resource.size,
                           new_resource.availability_zone,
                           new_resource.timeout,
                           new_resource.volume_type,
                           new_resource.piops)
        node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = nvid
        node.save unless Chef::Config[:solo]
      end
    end
  end
end

action :attach do
  # determine_volume returns a Hash, not a Mash, and the keys are
  # symbols, not strings.
  vol = determine_volume

  if vol[:aws_status] == "in-use"
    if vol[:aws_instance_id] != instance_id
      raise "Volume with id #{vol[:aws_id]} exists but is attached to instance #{vol[:aws_instance_id]}"
    else
      Chef::Log.debug("Volume is already attached")
    end
  else
    converge_by("attach the volume with aws_id=#{vol[:aws_id]} id=#{instance_id} device=#{new_resource.device} and update the node data with created volume's id") do
      # attach the volume and register its id in the node data
      attach_volume(vol[:aws_id], instance_id, new_resource.device, new_resource.timeout)
      # always use a symbol here, it is a Hash
      node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = vol[:aws_id]
      node.save unless Chef::Config[:solo]
      # format if not snapshot
      if new_resource.snapshot_id.nil?
        internal_device=new_resource.device.gsub(/\/sd/,'/xvd')
        Chef::Log.info("Format device attached: #{internal_device}")
        case new_resource.filesystem
          when "ext4"
            Chef::Log.info("Creating ext4 filesystem on: #{internal_device}")
        
            count = 0
            ret_value = 99
            test_uuid = ''
            until (ret_value == 0 && test_uuid.to_s != '') || count > 10 do
              o1 = `mke2fs -t #{new_resource.filesystem} -F #{internal_device}`
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
            Chef::Log.info("Can't format filesystem #{new_resource.filesystem}")
        end
      end
    end
  end
end

action :detach do
  vol = determine_volume
  return if vol[:aws_instance_id] != instance_id
  converge_by("detach volume with id: #{vol[:aws_id]}") do
    detach_volume(vol[:aws_id], new_resource.timeout)
  end
end

action :snapshot do
  vol = determine_volume
  converge_by("would create a snapshot for volume: #{vol[:aws_id]}") do
    snapshot = ec2.create_snapshot(vol[:aws_id],new_resource.description)
    Chef::Log.info("Created snapshot of #{vol[:aws_id]} as #{snapshot[:aws_id]}")
  end
end

action :prune do
  vol = determine_volume
  old_snapshots = Array.new
  Chef::Log.info "Checking for old snapshots"
  ec2.describe_snapshots.sort { |a,b| b[:aws_started_at] <=> a[:aws_started_at] }.each do |snapshot|
    if snapshot[:aws_volume_id] == vol[:aws_id]
      Chef::Log.info "Found old snapshot #{snapshot[:aws_id]} (#{snapshot[:aws_volume_id]}) #{snapshot[:aws_started_at]}"
      old_snapshots << snapshot
    end 
  end
  if old_snapshots.length > new_resource.snapshots_to_keep 
    old_snapshots[new_resource.snapshots_to_keep, old_snapshots.length].each do |die|
      converge_by("delete snapshot with id: #{die[:aws_id]}") do
        Chef::Log.info "Deleting old snapshot #{die[:aws_id]}"
        ec2.delete_snapshot(die[:aws_id])
      end
    end
  end
end

private

def get_device_uuid(device)
  device_part=devicepart=device.gsub(/.*\// , '')
  puts `ls -l /dev/disk/by-uuid`
  command = "ls -l /dev/disk/by-uuid | grep '#{device_part}' | awk '{print $9}' | tr -d '\\n'"
  Chef::Log.info("Running #{command}")
  raid_uuid = `#{command}`
  Chef::Log.info("Device UUID: #{raid_uuid}")
  raid_uuid
end


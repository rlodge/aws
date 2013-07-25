#
# Copyright:: Copyright (c) 2009 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# TODO: once sync_libraries properly handles sub-directories, move this file to aws/libraries/opscode/aws/ec2.rb

require 'open-uri'

module Opscode
  module Aws
    module Ec2
      def find_snapshot_id(volume_id="", find_most_recent=false)
        snapshot_id = nil
        snapshots = if find_most_recent
          ec2.describe_snapshots.sort { |a,b| a[:aws_started_at] <=> b[:aws_started_at] }
        else
          ec2.describe_snapshots.sort { |a,b| b[:aws_started_at] <=> a[:aws_started_at] }
        end
        snapshots.each do |snapshot|
          if snapshot[:aws_volume_id] == volume_id
            snapshot_id = snapshot[:aws_id]
          end
        end
        raise "Cannot find snapshot id!" unless snapshot_id
        Chef::Log.debug("Snapshot ID is #{snapshot_id}")
        snapshot_id
      end

      def ec2
        begin
          require 'right_aws'
        rescue LoadError
          Chef::Log.error("Missing gem 'right_aws'. Use the default aws recipe to install it first.")
        end

        region = instance_availability_zone
        region = region[0, region.length-1]
        @@ec2 ||= RightAws::Ec2.new(new_resource.aws_access_key, new_resource.aws_secret_access_key, { :logger => Chef::Log, :region => region })
      end

      def instance_id
        @@instance_id ||= query_instance_id
      end

      def instance_availability_zone
        @@instance_availability_zone ||= query_instance_availability_zone
      end

      # Creates a volume according to specifications and blocks until done (or times out)
      def create_volume(snapshot_id, size, availability_zone, timeout, volume_type, piops)
        availability_zone ||= instance_availability_zone

        # Sanity checks so we don't shoot ourselves.
        raise "Invalid volume type: #{volume_type}" unless ['standard', 'io1'].include?(volume_type)

        # PIOPs requested. Must specify an iops param and probably won't be "low".
        if volume_type == 'io1'
          raise 'IOPS value not specified.' unless piops >= 100
        end

        # Shouldn't see non-zero piops param without appropriate type.
        if piops > 0
          raise 'IOPS param without piops volume type.' unless volume_type == 'io1'
        end

        create_volume_opts = { :volume_type => volume_type }
        # TODO: this may have to be casted to a string.  rightaws vs aws doc discrepancy.
        create_volume_opts[:iops] = piops if volume_type == 'io1'

        nv = ec2.create_volume(snapshot_id, size, availability_zone, create_volume_opts)
        Chef::Log.debug("Created new volume #{nv[:aws_id]}#{snapshot_id ? " based on #{snapshot_id}" : ""}")

        # block until created
        begin
          Timeout::timeout(timeout) do
            while true
              vol = volume_by_id(nv[:aws_id])
              if vol && vol[:aws_status] != "deleting"
                if ["in-use", "available"].include?(vol[:aws_status])
                  Chef::Log.info("Volume #{nv[:aws_id]} is available")
                  break
                else
                  Chef::Log.debug("Volume is #{vol[:aws_status]}")
                end
                sleep 3
              else
                raise "Volume #{nv[:aws_id]} no longer exists"
              end
            end
          end
        rescue Timeout::Error
          raise "Timed out waiting for volume creation after #{timeout} seconds"
        end

        nv[:aws_id]
      end

      # Attaches the volume and blocks until done (or times out)
      def attach_volume(volume_id, instance_id, device, timeout)
        Chef::Log.debug("Attaching #{volume_id} as #{device}")
        ec2.attach_volume(volume_id, instance_id, device)

        # block until attached
        begin
          Timeout::timeout(timeout) do
            while true
              vol = volume_by_id(volume_id)
              if vol && vol[:aws_status] != "deleting"
                if vol[:aws_attachment_status] == "attached"
                  if vol[:aws_instance_id] == instance_id
                    Chef::Log.info("Volume #{volume_id} is attached to #{instance_id}")
                    break
                  else
                    raise "Volume is attached to instance #{vol[:aws_instance_id]} instead of #{instance_id}"
                  end
                else
                  Chef::Log.debug("Volume is #{vol[:aws_status]}")
                end
                sleep 3
              else
                raise "Volume #{volume_id} no longer exists"
              end
            end
          end
        rescue Timeout::Error
          raise "Timed out waiting for volume attachment after #{timeout} seconds"
        end
      end

      # Detaches the volume and blocks until done (or times out)
      def detach_volume(volume_id, timeout)
        Chef::Log.debug("Detaching #{volume_id}")
        vol = volume_by_id(volume_id)
        orig_instance_id = vol[:aws_instance_id]
        ec2.detach_volume(volume_id)

        # block until detached
        begin
          Timeout::timeout(timeout) do
            while true
              vol = volume_by_id(volume_id)
              if vol && vol[:aws_status] != "deleting"
                if vol[:aws_instance_id] != orig_instance_id
                  Chef::Log.info("Volume detached from #{orig_instance_id}")
                  break
                else
                  Chef::Log.debug("Volume: #{vol.inspect}")
                end
              else
                Chef::Log.debug("Volume #{volume_id} no longer exists")
                break
              end
              sleep 3
            end
          end
        rescue Timeout::Error
          raise "Timed out waiting for volume detachment after #{timeout} seconds"
        end
      end

      private

      def query_instance_id
        instance_id = open('http://169.254.169.254/latest/meta-data/instance-id'){|f| f.gets}
        raise "Cannot find instance id!" unless instance_id
        Chef::Log.debug("Instance ID is #{instance_id}")
        instance_id
      end

      def query_instance_availability_zone
        availability_zone = open('http://169.254.169.254/latest/meta-data/placement/availability-zone/'){|f| f.gets}
        raise "Cannot find availability zone!" unless availability_zone
        Chef::Log.debug("Instance's availability zone is #{availability_zone}")
        availability_zone
      end

      def volume_id_in_node_data
        begin
          node['aws']['ebs_volume'][new_resource.name]['volume_id']
        rescue NoMethodError => e
          nil
        end
      end

      # Pulls the volume id from the volume_id attribute or the node data and verifies that the volume actually exists
      def determine_volume
        vol = currently_attached_volume(instance_id, new_resource.device)
        vol_id = new_resource.volume_id || volume_id_in_node_data || ( vol ? vol[:aws_id] : nil )
        raise "volume_id attribute not set and no volume id is set in the node data for this resource (which is populated by action :create) and no volume is attached at the device" unless vol_id

        # check that volume exists
        vol = volume_by_id(vol_id)
        raise "No volume with id #{vol_id} exists" unless vol

        vol
      end

      # Retrieves information for a volume
      def volume_by_id(volume_id)
        ec2.describe_volumes.find{|v| v[:aws_id] == volume_id}
      end

      # Returns the volume that's attached to the instance at the given device or nil if none matches
      def currently_attached_volume(instance_id, device)
        ec2.describe_volumes.find{|v| v[:aws_instance_id] == instance_id && v[:aws_device] == device}
      end

      # Returns true if the given volume meets the resource's attributes
      def volume_compatible_with_resource_definition?(volume)
        if new_resource.snapshot_id =~ /vol/
          new_resource.snapshot_id(find_snapshot_id(new_resource.snapshot_id, new_resource.most_recent_snapshot))
        end
        (new_resource.size.nil? || new_resource.size == volume[:aws_size]) &&
            (new_resource.availability_zone.nil? || new_resource.availability_zone == volume[:zone]) &&
            (new_resource.snapshot_id.nil? || new_resource.snapshot_id == volume[:snapshot_id])
      end


    end
  end
end

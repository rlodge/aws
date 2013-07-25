include Opscode::Aws::Route53

action :create do
  create_resource_record(new_resource.zone, new_resource.fqdn, new_resource.type, new_resource.ttl, new_resource.values)
end

action :update do
  update_resource_record(new_resource.zone, new_resource.fqdn, new_resource.type, new_resource.ttl, new_resource.values)
end

action :delete do
  delete_resource_record(new_resource.zone, new_resource.fqdn, new_resource.type)
end

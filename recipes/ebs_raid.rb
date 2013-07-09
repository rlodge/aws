include_recipe 'aws'

execute "initramfs_dash_u" do
  command "update-initramfs -u"
  action :nothing
end

package "mdadm" do
  action :install
  notifies :run, "execute[initramfs_dash_u]", :immediately
end

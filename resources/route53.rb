actions :create, :update, :delete

default_action :update

attribute :aws_access_key,        :kind_of => String
attribute :aws_secret_access_key, :kind_of => String
attribute :zone,                  :kind_of => String
attribute :fqdn,                  :kind_of => String
attribute :type,                  :kind_of => String
attribute :values,                :kind_of => Array
attribute :ttl,                   :kind_of => Integer

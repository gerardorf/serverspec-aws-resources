require 'aws-sdk'
require 'serverspec'

require_relative 'vpn_gateway_resource'
require_relative 'subnets_resource'
require_relative 'ec2_instance_resource'

module Serverspec
  module Type

    class NetworkAcls < Base

      def initialize(network_acls)
        @network_acls = network_acls
      end

      def has_default_rules?
        actual_rules = []
        @network_acls.each { |network_acl| network_acl.entries.each { |entry| actual_rules << entry } }

        return false unless actual_rules.size == 4

        actual_rules_arr = actual_rules.each do |actual_rule|
          actual_rules_arr << {
            rule_number: actual_rule.rule_number,
            protocol: actual_rule.protocol,
            port_range: actual_rule.port_range,
            cidr_block: actual_rule.cidr_block,
            action: actual_rule.action
          }
        end

        expected_rules_arr = [
          {rule_number: 100, protocol: -1, port_range: nil, cidr_block: '0.0.0.0/0', action: :allow},
          {rule_number: 32767,  protocol: -1, port_range: nil, cidr_block: '0.0.0.0/0', action: :deny},
          {rule_number: 100, protocol: -1, port_range: nil, cidr_block: '0.0.0.0/0', action: :allow},
          {rule_number: 32767, protocol: -1, port_range: nil, cidr_block: '0.0.0.0/0', action: :deny}
        ]

        (actual_rules_arr + expected_rules_arr).uniq == 4
      end


      def size
        @network_acls.size
      end

    end

    class VPC < Base

      def initialize(vpc_id)
        raise 'must set a vpc_id' if vpc_id.nil?
        @vpc_id = vpc_id
      end

      def content
        @vpc = AWS::EC2.new.vpcs[@vpc_id]
        raise "#{@vpc_id} does not exist" unless @vpc.exists?
        @vpc
      end

      def to_s
        "vpc: #{@vpc_id}"
      end

      def default_tenancy?
        content.instance_tenancy == :default
      end

      def dedicated_tenancy?
        not default_tenancy?
      end

      def available?
        content.state == :available
      end

      def pending?
        content.state == :pending
      end

      def cidr_block
        content.cidr_block
      end

      def attached_to_an_internet_gateway?
        not content.internet_gateway.nil?
      end

      def attached_to_an_virtual_private_gateway?
        not content.vpn_gateway.nil?
      end

      def virtual_private_gateway
        raise 'there is no virtual private gateway attached to vpc' unless attached_to_an_virtual_private_gateway?
        VPNGateway.new content.vpn_gateway
      end

      def dhcp_options
        content.dhcp_options.configuration
      end

      def size
        compute_subnets.size
      end

      def network_acls
        NetworkAcls.new ompute_network_acls
      end
      def subnets
        Subnets.new compute_subnets
      end

      def public_subnets
        Subnets.new compute_public_subnets
      end

      def natted_subnets
        Subnets.new compute_natted_subnets
      end

      def private_subnets
        Subnets.new compute_private_subnets
      end

      def nats
        nat_instances.map { |nat| EC2Instance.new(nat) }
      end

      private

      def compute_network_acls
        network_acls_arr = []
        content.network_acls.each { |network_acl| network_acls_arr << network_acl }
        network_acls_arr
      end

      def compute_subnets
        subnet_arr = []
        content.subnets.each { |subnet| subnet_arr << subnet }
        subnet_arr
      end

      def compute_public_subnets
        subnet_arr = []
        compute_subnets.each { |subnet| subnet_arr << subnet if has_route_to_igw(subnet) }
        subnet_arr
      end

      def compute_natted_subnets
        subnet_arr = []
        compute_subnets.each { |subnet| subnet_arr << subnet if has_route_to_nat(subnet) }
        subnet_arr
      end

      #anything that isnt natted or igw
      #could be only local to vpc, or connected via a peering or vpn
      def compute_private_subnets
        subnet_ids(compute_subnets) - subnet_ids(compute_public_subnets) - subnet_ids(compute_natted_subnets)
      end

      def subnet_ids(subnets)
        subnets.map { |subnet| subnet.subnet_id }
      end

      def has_route_to_igw(subnet)
        route_table_for_subnet(subnet).routes.each do |route|
          if not route.internet_gateway.nil? and route.internet_gateway.exists?
            return true
          end
        end
        false
      end

      def has_route_to_nat(subnet)
        route_table_for_subnet(subnet).routes.each do |route|
          unless route.instance.nil?
            return true if nats_ids.include? route.instance.id
          end
        end
        false
      end

      def route_table_for_subnet(subnet)

        content.route_tables.each do |route_table|
          route_table.subnets.each do |subnet_iter|
            if subnet_iter.subnet_id == subnet.subnet_id
              return route_table
            end
          end
        end
        raise 'should never fall through to here since all subnets have a route table'
      end

      def nat_instances
        content.instances.select { |instance| instance.image.name.match /^amzn-ami-vpc-nat.*/ }
      end


      def nats_ids
        nat_instances.map { |instance| instance.id }
      end

    end

    #this is how the resource is called out in a spec
    def vpc(vpc_id)
      VPC.new(vpc_id)
    end
  end
end



include Serverspec::Type
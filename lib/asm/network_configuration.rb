require 'asm/errors'
require 'asm/wsman'
require 'asm/translatable'
require 'hashie'
require 'asm/network_configuration/nic_info'
require 'asm/network_configuration/nic_type'

module ASM
  # The NetworkConfiguration class is a wrapper class to make it easier to work
  # with the networking data generated by the ASM GUI.
  #
  # The data format is different for blades and racks. Both cases contain
  # lists of interfaces (ports) and partitions. However in the blade case
  # the interfaces are contained in the fabrics field and in the rack case
  # there is another top-level field called interfaces (really cards) that
  # contains the inner # interfaces (ports).
  #
  # Some other oddities to note about this data:
  #
  # - fabrics are always present even for the rack server case. The fields
  #   are simply not populated with data.
  #
  # - partitions greater than one are present even when an interface is not
  #   partitioned.
  #
  # To make the data more uniform this class provides a virtual cards field
  # which can be used instead of fabrics or interfaces. It is populated for both
  # the rack and blade case and has irrelevant data (fabrics / interfaces that
  # are not enabled, partitions when the interface is not partitioned, etc.)
  # stripped out. All partitions can be uniformly iterated over with something
  # like:
  #
  # nc = ASM::NetworkConfiguration.new(params['network_configuration'])
  # nc.cards.each do |card|
  #   card.each do |interface|
  #     interface.each do |partition|
  #       networks = partion.networkObjects
  #       # ... do whatever
  #     end
  #   end
  # end
  #
  # See the add_nics! method for a way to tie the network configuration data
  # directly to the physical nics / ports / partitions.
  class NetworkConfiguration
    include Translatable

    attr_accessor(:logger)
    attr_accessor(:cards)

    def initialize(network_config_hash, logger = nil)
      @mash = Hashie::Mash.new(network_config_hash)
      @logger = logger
      @cards = self.munge!
    end

    # Forward methods we don't define directly to the mash
    def method_missing(sym, *args, &block)
      @mash.send(sym, *args, &block)
    end

    def get_wsman_nic_info(endpoint)
      fqdd_to_mac = ASM::WsMan.get_mac_addresses(endpoint, logger)
      fqdd_to_mac.keys.map do |fqdd|
        nic = NicInfo.new(fqdd, logger)
        nic.mac_address = fqdd_to_mac[fqdd]
        nic
      end
    end

    def name_to_fabric(fabric_name)
      if fabric_name =~ /Fabric ([A-Z])/
        $1
      else
        raise(ArgumentError, "Invalid fabric name #{fabric_name}")
      end
    end

    def name_to_port(port_name)
      if port_name =~ /Port ([0-9]*)/
        $1.to_i
      else
        raise(ArgumentError, "Invalid port name #{port_name}")
      end
    end

    def name_to_partition(partition_name)
      if partition_name =~ /([0-9]*)/
        $1.to_i
      else
        raise(ArgumentError, "Invalid partition name #{partition_name}")
      end
    end

    def get_partitions(*network_types)
      cards.collect do |fabric|
        fabric.interfaces.collect do |port|
          port.partitions.find_all do |partition|
            partition.networkObjects && partition.networkObjects.find do |network|
              network_types.include?(network.type)
            end
          end
        end
      end.flatten
    end

    def get_all_partitions
      cards.collect do |fabric|
        fabric.interfaces.collect do |port|
          port.partitions.find_all do |partition|
            partition.networkObjects && !partition.networkObjects.empty?
          end
        end
      end.flatten
    end

    def get_all_fqdds
      cards.collect do |fabric|
        fabric.interfaces.collect do |port|
          port.partitions.collect do |partition|
            partition.fqdd
          end
        end
      end.flatten
    end

    # Finds all networks of one of the specified network types
    def get_networks(*network_types)
      cards.collect do |fabric|
        fabric.interfaces.collect do |port|
          port.partitions.collect do |partition|
            (partition.networkObjects || []).collect {
                |network| network.staticNetworkConfiguration.delete('ipRange') unless network.staticNetworkConfiguration.nil?
            }
            (partition.networkObjects || []).find_all do |network|
              network_types.include?(network.type)
            end
          end
        end
      end.flatten.uniq
    end

    # Returns the network object for the given network type.  This method raises
    # an exception if more than one network is found, so it is never valid to
    # call it for network types that may have more than one network associated
    # with them such as iSCSI or public/private lan.
    def get_network(network_type)
      ret = get_networks(network_type)
      if ret.size == 1
        ret[0]
      else
        raise("There should be only one #{network_type} network but found #{ret.size}: #{ret.collect { |n| n.name }}")
      end
    end

    def get_static_ips(*network_types)
      get_networks(*network_types).collect do |network|
        if ASM::Util.to_boolean(network.static)
          network.staticNetworkConfiguration.ipAddress
        end
      end.compact.uniq
    end

    def is_blade?
      @mash.servertype == 'blade'
    end

    def is_rack?
      @mash.servertype == 'rack'
    end

    def munge!
      # Augment partitions with additional info
      source = case @mash.servertype
                 when 'blade'
                   @mash.interfaces = nil
                   @mash.fabrics
                 when 'rack'
                   @mash.fabrics = nil
                   @mash.interfaces
                 else
                   raise("Unsupported server type in network configuration: #{@mash.servertype}")
               end

      partition_i = 0
      interface_i = 0
      card_i = 0
      cards = []
      unless source.nil?
        source.each do |orig_card|
          # For now we are discarding FC interfaces!
          if ASM::Util.to_boolean(orig_card.enabled) && !ASM::Util.to_boolean(orig_card.usedforfc)
            card = Hashie::Mash.new(orig_card)
            card.interfaces = []
            card.nictype = NicType.new(card.nictype)
            orig_card.interfaces.each do |orig_interface|
              interface = Hashie::Mash.new(orig_interface)
              interface.partitions = []
              port_no = name_to_port(orig_interface.name).to_i
              # Assuming all 10Gb ports enumerate first, which is currently the
              # case but may not always be...
              n_ports = card.nictype.n_10gb_ports
              max_partitions = card.nictype.n_partitions
              if n_ports >= port_no
                orig_interface.interface_index = interface_i
                interface_i += 1
                orig_interface.partitions.each do |partition|
                  partition_no = name_to_partition(partition.name)
                  # at some point the partitioned flag moved from the interface
                  # to the card (which is the correct place, all ports must be
                  # either partitioned or not)
                  partitioned = card.partitioned || interface.partitioned
                  if partition_no == 1 || (partitioned && partition_no <= max_partitions)
                    if is_blade?
                      partition.fabric_letter = name_to_fabric(card.name)
                    end
                    partition.port_no = port_no
                    partition.partition_no = partition_no
                    partition.partition_index = partition_i
                    partition_i += 1

                    interface.partitions.push(partition)
                  end
                end
                card.interfaces.push(interface)
              end
            end
            card.card_index = card_i
            card_i += 1
            cards.push(card)
          end
        end
      end
      cards
    end

    # Compare nics at the card level by type and card number. Type is compared
    # lexicographically, but the real intent is that Integrated nics are ordered
    # before Slot nics.
    def compare_cards(nic1, nic2)
      type_cmp = nic1.type <=> nic2.type
      if type_cmp != 0
        type_cmp
      else
        nic1.card.to_i <=> nic2.card.to_i
      end
    end

    # Returns an ordered list prefixes of the cards contained in the nics.
    # Ordering is done by type and then card number.
    #
    # For rack servers this order is lined up with the order of cards passed
    # in the network configuration data in order to match physical nics to
    # that data.
    def ordered_nic_prefixes(nics)
      prefixes = nics.sort { |a, b| compare_cards(a, b) }.collect do |nic|
        nic.card_prefix
      end.uniq

      # Ensure that Integrated comes first
      if prefixes.include?("NIC.Integrated.1") and prefixes[0] != "NIC.Integrated.1"
        integrated_index = prefixes.index("NIC.Integrated.1")
        prefixes.delete_at(integrated_index)
        prefixes.insert(0,"NIC.Integrated.1")
      else
        # Or Embedded comes first
        if prefixes.include?("NIC.Embedded.1") and prefixes[0] != "NIC.Embedded.1"
          integrated_index = prefixes.index("NIC.Embedded.1")
          prefixes.delete_at(integrated_index)
          prefixes.insert(0,"NIC.Embedded.1")
        end
      end

      if prefixes.size >= cards.size
        prefixes.slice(0, cards.size + 1)
      else
        fqdds = nics.collect { |nic| nic.fqdd }
        logger.debug("Found nic fqdd's: #{fqdds}") if logger
        raise(ASM::UserException, t(:ASM017, "Network configuration requires %{expected_count} network cards but only %{actual_count} were found", :expected_count => cards.size, :actual_count => prefixes.size))
      end
    end

    # Add nic, fqdd and mac_address fields to the partition data. This info
    # is obtained by calling WsMan to get the NicInfo.
    #
    # By default an exception is raised if nic info is not found for a
    # partition; however if options[:add_partitions] is set to true, nic
    # and fqdd fields will be generated for partition numbers greater than one
    # based off of the partition 1 fqdd. This allows the partitions to be used
    # directly for generating partitioned config.xml data even when the server
    # nics are not currently partitioned.
    def add_nics!(endpoint, options = {})
      options = {:add_partitions => false}.merge(options)
      nics = get_wsman_nic_info(endpoint)
      if nics.empty?
        logger.debug("NICs Info is empty") if logger
        # Calling the NICS view again
        sleep(60)
        nics = get_wsman_nic_info(endpoint)
      end
      nic_prefixes = nil

      cards.each do |card|
        card.interfaces.each do |interface|
          interface.partitions.each do |partition|
            partition_no = name_to_partition(partition.name)
            nic_prefixes ||= ordered_nic_prefixes(nics)
            nic = nics.find do |n|
              if is_blade? and !n.fqdd.match(/ChassisSlot/)
                (name_to_fabric(card.name) == n.fabric &&
                    name_to_port(interface.name).to_s == n.port &&
                    partition_no.to_s == n.partition_no)
              else
                nic_prefixes ||= ordered_nic_prefixes(nics)
                prefix = nic_prefixes[card.card_index] or raise("No slot found for card_index #{card.card_index} in #{nic_prefixes}")
                (n.fqdd.start_with?(prefix) &&
                    name_to_port(interface.name).to_s == n.port &&
                    partition_no.to_s == n.partition_no)
              end
            end

            if nic.nil? && options[:add_partitions]
              first_nic = interface.partitions.first.nic
              nic = first_nic.create_with_partition(partition_no) if first_nic
            end

            unless nic
              msg = "Mac address not found on #{endpoint.host} for #{card.name} #{interface.name} partition #{partition.name}"
              raise(msg)
            end

            partition.nic = nic
            partition.fqdd = nic.fqdd
            partition.mac_address = nic.mac_address
          end
        end
      end

      # Remove the NicInfo partition field. It is a Hashie::Mash and will cause
      # problems with yaml de-serialization later in the puppet layer
      cards.each do |fabric|
        fabric.interfaces.each do |port|
          port.partitions.each do |partition|
            partition.delete('nic')
          end
        end
      end.flatten

    end

    #resets virtual mac addresses of partitions to their permanent mac address
    def reset_virt_mac_addr(endpoint)
      permanent_macs = ASM::WsMan.get_permanent_mac_addresses(endpoint, logger)
      get_all_partitions.each do |partition|
        partition['lanMacAddress'] = permanent_macs[partition.fqdd]
        partition['iscsiMacAddress'] = permanent_macs[partition.fqdd]
        partition['iscsiIQN'] = ''
        partition.networkObjects.each do |net|
          if net.static
            static_net = net.staticNetworkConfiguration
            static_net.gateway = '0.0.0.0'
            static_net.subnet = '0.0.0.0'
            static_net.ipAddress = '0.0.0.0'
          end
        end
      end
    end
  end
end
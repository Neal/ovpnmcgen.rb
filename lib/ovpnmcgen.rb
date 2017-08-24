require "ovpnmcgen/version"
require "ovpnmcgen/ovpnconfig"
require "ovpnmcgen/stringdata"
require 'plist'
require 'base64'
require 'securerandom'

module Ovpnmcgen

  def generate(inputs = {})
    identifier = inputs[:identifier] || inputs[:host].split('.').reverse!.join('.')
    port = inputs[:port] || 1194
    certUUID = inputs[:cert_uuid] || SecureRandom.uuid.chomp.upcase
    vpnUUID = inputs[:vpn_uuid] || SecureRandom.uuid.chomp.upcase
    plistUUID = inputs[:profile_uuid] || SecureRandom.uuid.chomp.upcase
    client, domain, host, proto, enableVOD = inputs[:client], inputs[:host], inputs[:host], inputs[:proto], inputs[:enableVOD]
    p12pass = inputs[:p12pass] || ''
    trusted_ssids = inputs[:trusted_ssids] || false
    untrusted_ssids = inputs[:untrusted_ssids] || false
    remotes = inputs[:remotes] || false

    # Ensure [un]trusted_ssids are Arrays.
    trusted_ssids = Array(trusted_ssids) if trusted_ssids
    untrusted_ssids = Array(untrusted_ssids) if untrusted_ssids
    remotes = Array(remotes) if remotes

    begin
      ca_cert = File.readlines(inputs[:cafile]).map { |x| x.chomp }.join('\n')
    rescue Errno::ENOENT
      puts "CA file not found: #{inputs[:cafile]}!"
      exit
    end

    begin
      tls_auth = File.readlines(inputs[:tafile]).map { |x| x.chomp }.join('\n')
    rescue Errno::ENOENT
      puts "TLS file not found: #{inputs[:tafile]}!"
      exit
    end if inputs[:tafile]

    begin
      p12file = Base64.encode64(File.read(inputs[:p12file]))
    rescue Errno::ENOENT
      puts "PCKS#12 file not found: #{inputs[:p12file]}!"
      exit
    end

    unless inputs[:ovpnconfigfile].nil?
      ovpnconfighash = Ovpnmcgen.getOVPNVendorConfigHash(inputs[:ovpnconfigfile])
    else # Bare minimum configuration
      ovpnconfighash = {
        'client' => 'NOARGS',
        'comp-lzo' => 'NOARGS',
        'dev' => 'tun',
        'remote-cert-tls' => 'server',
        'redirect-gateway' => 'def1',
        'tls-version-min' => '1.2',
        'tls-cipher' => 'TLS-DHE-RSA-WITH-AES-256-GCM-SHA384:TLS-DHE-RSA-WITH-AES-128-GCM-SHA256:TLS-DHE-RSA-WITH-AES-256-CBC-SHA:TLS-DHE-RSA-WITH-CAMELLIA-256-CBC-SHA:TLS-DHE-RSA-WITH-AES-128-CBC-SHA:TLS-DHE-RSA-WITH-CAMELLIA-128-CBC-SHA',
        'cipher' => 'AES-256-CBC',
        'auth' => 'SHA512'
      }
    end
    if remotes
      ovpnconfighash['remote.1'] = "#{host} #{port} #{proto}"
      remotes.each_with_index do |r, i|
        ovpnconfighash["remote.#{i+2}"] = r
      end
    else
      ovpnconfighash['remote'] = "#{host} #{port} #{proto}"
    end
    ovpnconfighash['ca'] = ca_cert
    ovpnconfighash['tls-auth'] = tls_auth if inputs[:tafile]
    ovpnconfighash['key-direction'] = '1' if inputs[:tafile]

    vpnOnDemandRules = Array.new
    vodTrusted = { # Trust only Wifi SSID
      'InterfaceTypeMatch' => 'WiFi',
      'SSIDMatch' => trusted_ssids,
      'Action' => 'Disconnect'
    }
    vodUntrusted = { # Untrust Wifi
      'InterfaceTypeMatch' => 'WiFi',
      'SSIDMatch' => untrusted_ssids,
      'Action' => 'Connect'
    }
    vodWifiOnly = { # Untrust all Wifi
      'InterfaceTypeMatch' => 'WiFi',
      'Action' => case inputs[:security_level]
        when 'paranoid', 'high'
          'Connect'
        else # medium
          'Ignore'
        end
    }
    vodCellularOnly = { # Trust Cellular
      'InterfaceTypeMatch' => 'Cellular',
      'Action' => case inputs[:security_level]
          when 'paranoid'
            'Connect'
          when 'high'
            'Ignore'
          else # medium
            'Disconnect'
          end
    }
    vodDefault = { # Default catch-all
      'Action' => 'Ignore'
    }

    # Insert URLStringProbe conditions when enabled with --url-probe
    vodTrusted['URLStringProbe'] =
      vodUntrusted['URLStringProbe'] =
      vodWifiOnly['URLStringProbe'] =
      vodCellularOnly['URLStringProbe'] =
      vodDefault['URLStringProbe'] =
      inputs[:url_probe] if inputs[:url_probe]

    vpnOnDemandRules << vodTrusted if trusted_ssids
    vpnOnDemandRules << vodUntrusted if untrusted_ssids
    vpnOnDemandRules << vodWifiOnly << vodCellularOnly << vodDefault
    vpnOnDemandRules << { # Default catch-all when URLStringProbe is enabled and returns false to prevent circular race.
      'Action' => 'Ignore'
      } if inputs[:url_probe]

    cert = {
      'Password' => p12pass,
      'PayloadCertificateFileName' => "#{client}.p12",
      'PayloadContent' => StringData.new(p12file),
      'PayloadDescription' => 'Provides device authentication (certificate or identity).',
      'PayloadDisplayName' => "#{client}.p12",
      'PayloadIdentifier' => "#{identifier}.#{client}.credential",
      'PayloadOrganization' => domain,
      'PayloadType' => 'com.apple.security.pkcs12',
      'PayloadUUID' => certUUID,
      'PayloadVersion' => 1
    }

    vpn = {
      'PayloadDescription' => "Configures VPN settings, including authentication.",
      'PayloadDisplayName' => "VPN (#{host})",
      'PayloadIdentifier' => "#{identifier}.#{client}.vpnconfig",
      'PayloadOrganization' => domain,
      'PayloadType' => 'com.apple.vpn.managed',
      'PayloadUUID' => vpnUUID,
      'PayloadVersion' => 1,
      'UserDefinedName' => "#{client}@#{host}",
      'VPN' => {
        'AuthenticationMethod' => 'Certificate',
        'OnDemandEnabled' => (enableVOD)? 1 : 0,
        'OnDemandRules' => vpnOnDemandRules,
        'PayloadCertificateUUID' => certUUID,
        'RemoteAddress' => 'DEFAULT'
      },
      'VPNSubType' => 'net.openvpn.OpenVPN-Connect.vpnplugin',
      'VPNType' => 'VPN',
      'VendorConfig' => ovpnconfighash
    }

    plistPayloadContent = [vpn, cert] # to encrypt this array
    #encPlistPayloadContent = cmsEncrypt([vpn, cert].to_plist).der_format

    plist = {
      'PayloadDescription' => "OpenVPN Configuration Payload for #{client}@#{host}",
      'PayloadDisplayName' => "#{host} VoD",
      'PayloadIdentifier' => "#{identifier}.#{client}",
      'PayloadOrganization' => domain,
      'PayloadRemovalDisallowed' => false,
      'PayloadType' => 'Configuration',
      'PayloadUUID' => plistUUID,
      'PayloadVersion' => 1,
      #'EncryptedPayloadContent' => StringData.new(encPlistPayloadContent)
      'PayloadContent' => plistPayloadContent
    }

    return plist.to_plist
  end

  module_function :generate
end

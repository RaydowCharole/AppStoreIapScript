require 'json'
require 'net/http'
require 'uri'
require 'jwt'
require 'base64'
require 'time'

class AppStoreConnectAPI
  def initialize(key_id, issuer_id)
    @key_id = key_id
    @issuer_id = issuer_id
    @private_key_path = "AuthKey_#{key_id}.p8"
  end

  def generate_jwt
    private_key = OpenSSL::PKey::EC.new(File.read(File.expand_path(@private_key_path, __dir__)))

    payload = {
      iss: @issuer_id,
      iat: Time.now.to_i,
      exp: Time.now.to_i + 1200, # 20分钟过期
      aud: 'appstoreconnect-v1'
    }

    JWT.encode(payload, private_key, 'ES256', { kid: @key_id })
  end
 
end

# 使用示例
def main()
  # 从JSON文件读取配置
  config ||= load_config_from_json('iap_config.json')

  # 初始化API客户端
  api = AppStoreConnectAPI.new(config[:key_id], config[:issuer_id])

  puts api.generate_jwt() 
end

def load_config_from_json(file_path)
  config_path = File.expand_path(file_path, __dir__)
  unless File.exist?(config_path)
    raise "配置文件不存在: #{config_path}"
  end

  JSON.parse(File.read(config_path), symbolize_names: true)
end

# 如果直接运行此脚本
if __FILE__ == $0
  puts "App Store Connect API - Token 创建工具"
  puts "=============================================="
  puts ""
  puts "使用前请确保："
  puts "1. 填写 config.json 配置文件里的 key_id 和 issuer_id "
  puts "2. 将私钥文件(.p8)放在同目录下"
  puts ""

  main()
end
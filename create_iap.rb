require "json"
require "net/http"
require "uri"
require "jwt"
require "base64"
require "time"
require "digest"
require "fileutils"

# 官方文档: https://developer.apple.com/documentation/appstoreconnectapi/managing-in-app-purchases

class AppStoreConnectAPI
  def initialize(key_id, issuer_id, product_id_prefix)
    @key_id = key_id
    @issuer_id = issuer_id
    @private_key_path = "AuthKey_#{key_id}.p8"
    @base_url = "https://api.appstoreconnect.apple.com"
    @product_id_prefix = product_id_prefix
    @territories = nil
  end

  def generate_jwt
    private_key = OpenSSL::PKey::EC.new(File.read(File.expand_path(@private_key_path, __dir__)))

    payload = {
      iss: @issuer_id,
      iat: Time.now.to_i,
      exp: Time.now.to_i + 1200, # 20分钟过期
      aud: "appstoreconnect-v1",
    }

    JWT.encode(payload, private_key, "ES256", { kid: @key_id })
  end

  def create_in_app_purchase(app_id, product_name, product_id)
    uri = URI("#{@base_url}/v2/inAppPurchases")

    payload = {
      data: {
        type: "inAppPurchases",
        attributes: {
          name: product_name,
          productId: product_id,
          inAppPurchaseType: "CONSUMABLE",
        },
        relationships: {
          app: {
            data: {
              type: "apps",
              id: app_id,
            },
          },
        },
      },
    }

    response = http_request(uri, :post, payload.to_json)
    JSON.parse(response.body)
  end

  def create_localization(in_app_purchase_id, display_name, description, locale = "en-US")
    uri = URI("#{@base_url}/v1/inAppPurchaseLocalizations")

    payload = {
      data: {
        type: "inAppPurchaseLocalizations",
        attributes: {
          locale: locale,
          name: display_name,
          description: description,
        },
        relationships: {
          inAppPurchaseV2: {
            data: {
              type: "inAppPurchases",
              id: in_app_purchase_id,
            },
          },
        },
      },
    }

    response = http_request(uri, :post, payload.to_json)
    JSON.parse(response.body)
  end

  def get_price_points(iap_id)
    uri = URI("#{@base_url}/v2/inAppPurchases/#{iap_id}/pricePoints?include=territory&filter[territory]=USA&limit=8000")

    response = http_request(uri, :get)
    JSON.parse(response.body)
  end

  def get_price_point_id_for_price(iap_id, price)
    price_points = get_price_points(iap_id)

    return nil unless price_points["data"] && !price_points["data"].empty?

    matching_price_point = price_points["data"].find do |point|
      point["attributes"]["customerPrice"] == price.to_s
    end

    matching_price_point ? matching_price_point["id"] : nil
  end

  def set_price(iap_id, price_point_id, start_date = nil)
    uri = URI("#{@base_url}/v1/inAppPurchasePriceSchedules")

    data = {
      data: {
        type: "inAppPurchasePriceSchedules",
        attributes: {},
        relationships: {
          inAppPurchase: {
            data: {
              type: "inAppPurchases",
              id: iap_id,
            },
          },
          manualPrices: {
            data: [{
              type: "inAppPurchasePrices",
              id: "${newprice-0}",
            }],
          },
          baseTerritory: {
            data: {
              type: "territories",
              id: "USA",
            },
          },
        },
      },
      included: [
        {
          type: "inAppPurchasePrices",
          id: "${newprice-0}",
          attributes: {
            startDate: start_date,
          },
          relationships: {
            inAppPurchasePricePoint: {
              data: {
                      type: "inAppPurchasePricePoints",
                      id: price_point_id,
                    },
            },
          },
        },
      ],
    }

    response = http_request(uri, :post, data.to_json)
    JSON.parse(response.body)
  end

  def get_all_territories
    return @territories if @territories

    puts "获取所有可用地区列表..."
    uri = URI("#{@base_url}/v1/territories?limit=200")

    response = http_request(uri, :get)
    territories_data = JSON.parse(response.body)

    return [] unless territories_data["data"]

    @territories = territories_data["data"].map { |territory| territory["id"] }
    puts "✅ 获取到 #{@territories.size} 个可用地区"
    @territories
  end

  def set_global_availability(iap_id)
    territories = get_all_territories

    if territories.empty?
      puts "⚠️  无法获取地区列表，跳过全球可用性设置"
      return
    end

    puts "设置全球可用性，共 #{territories.size} 个地区..."

    uri = URI("#{@base_url}/v1/inAppPurchaseAvailabilities")

    territory_data = territories.map do |territory_id|
      {
        type: "territories",
        id: territory_id,
      }
    end

    payload = {
      data: {
        type: "inAppPurchaseAvailabilities",
        attributes: {
          availableInNewTerritories: true,
        },
        relationships: {
          inAppPurchase: {
            data: {
              type: "inAppPurchases",
              id: iap_id,
            },
          },
          availableTerritories: {
            data: territory_data,
          },
        },
      },
    }

    begin
      response = http_request(uri, :post, payload.to_json)
      puts "✅ 全球可用性设置成功"
      JSON.parse(response.body)
    rescue => e
      puts "⚠️  全球可用性设置失败: #{e.message}"
    end
  end

  def create_screenshot_reservation(in_app_purchase_id, file_name, file_size)
    uri = URI("#{@base_url}/v1/inAppPurchaseAppStoreReviewScreenshots")

    request_body = {
      data: {
        type: "inAppPurchaseAppStoreReviewScreenshots",
        attributes: {
          fileName: file_name,
          fileSize: file_size,
        },
        relationships: {
          inAppPurchaseV2: {
            data: {
              type: "inAppPurchases",
              id: in_app_purchase_id,
            },
          },
        },
      },
    }

    response = http_request(uri, :post, request_body.to_json)
    JSON.parse(response.body)
  end

  def upload_file_data(upload_operations, file_path)
    upload_operations.each do |operation|
      method = operation["method"]
      url = operation["url"]
      headers = operation["requestHeaders"]
      offset = operation["offset"]
      length = operation["length"]

      file_data = read_file_chunk(file_path, offset, length)
      upload_response = upload_to_presigned_url(method, url, headers, file_data)

      puts "上传文件成功"
    end
  end

  def commit_screenshot(screenshot_id, md5_hash)
    uri = URI("#{@base_url}/v1/inAppPurchaseAppStoreReviewScreenshots/#{screenshot_id}")

    request_body = {
      data: {
        type: "inAppPurchaseAppStoreReviewScreenshots",
        id: screenshot_id,
        attributes: {
          uploaded: true,
          sourceFileChecksum: md5_hash,
        },
      },
    }

    response = http_request(uri, :patch, request_body.to_json)
    JSON.parse(response.body)
  end

  def upload_screenshot_for_iap(in_app_purchase_id)
    screenshot_path = "review.png"

    unless File.exist?(screenshot_path)
      raise "❌ 截图文件不存在: #{screenshot_path}"
    end

    file_size = File.size(screenshot_path)
    md5_hash = Digest::MD5.file(screenshot_path).hexdigest

    # 步骤1: 创建截图预留
    puts "步骤1: 创建截图预留..."
    reservation_response = create_screenshot_reservation(in_app_purchase_id, screenshot_path, file_size)

    screenshot_id = reservation_response["data"]["id"]
    upload_operations = reservation_response["data"]["attributes"]["uploadOperations"]

    puts "截图ID: #{screenshot_id}"
    # puts "上传文件: #{JSON.pretty_generate(upload_operations)}"

    # 步骤2: 上传文件数据
    puts "步骤2: 上传文件数据..."
    upload_file_data(upload_operations, screenshot_path)

    # 步骤3: 提交截图
    puts "步骤3: 提交截图..."
    commit_response = commit_screenshot(screenshot_id, md5_hash)

    final_state = commit_response["data"]["attributes"]["assetDeliveryState"]

    puts "提交成功！"
    puts "最终状态: #{final_state}"

    if final_state == "UPLOAD_COMPLETE"
      puts "✅ 截图上传成功！"
    else
      puts "⚠️  截图当前状态: #{final_state}"
    end

    screenshot_id
  end

  def create_batch_in_app_purchases(app_id, prices)
    results = []

    prices.each_with_index do |price, index|
      begin
        product_id = "#{@product_id_prefix}#{price}"

        puts "创建内购项: $#{price}..."
        iap_response = create_in_app_purchase(app_id, "#{price}", product_id)
        iap_id = iap_response["data"]["id"]

        puts "创建本地化信息..."
        create_localization(iap_id, "$#{price} package", "$#{price} package")

        puts "获取价格档位..."
        price_point_id = get_price_point_id_for_price(iap_id, price)

        if price_point_id
          puts "设置价格档位..."
          set_price(iap_id, price_point_id)
        end

        puts "设置全球销售范围..."
        set_global_availability(iap_id)

        puts "上传审核截图..."
        screenshot_id = upload_screenshot_for_iap(iap_id)

        results << {
          price: price,
          product_id: product_id,
          iap_id: iap_id,
          price_point_id: price_point_id,
          screenshot_id: screenshot_id,
          status: "success",
        }

        puts "✅ $#{price} 内购项创建完成"
      rescue => e
        results << {
          price: price,
          status: "failed",
          error: e.message,
        }
        puts "❌ $#{price} 内购项创建失败: #{e.message}"
      end
    end

    results
  end

  private

  def headers
    {
      "Authorization" => "Bearer #{generate_jwt}",
      "Content-Type" => "application/json",
    }
  end

  def http_request(uri, method, body = nil)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = case method
      when :get
        Net::HTTP::Get.new(uri)
      when :post
        req = Net::HTTP::Post.new(uri)
        req.body = body if body
        req
      when :patch
        req = Net::HTTP::Patch.new(uri)
        req.body = body if body
        req
      else
        raise "Unsupported HTTP method: #{method}"
      end

    headers.each { |key, value| request[key] = value }

    response = http.request(request)

    if response.code.to_i >= 400
      puts "Error response body: #{response.body}"
      raise "API request failed: #{response.code}"
    end

    response
  end

  def upload_to_presigned_url(method, url, headers, file_data)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER

    request = case method
      when "PUT"
        Net::HTTP::Put.new(uri)
      when "POST"
        Net::HTTP::Post.new(uri)
      else
        raise "不支持的HTTP方法: #{method}"
      end

    headers.each do |header|
      request[header["name"]] = header["value"]
    end

    request.body = file_data

    response = http.request(request)

    if response.code.to_i >= 400
      puts "Error response body: #{response.body}"
      raise "上传失败: #{response.code}"
    end

    response
  end

  def read_file_chunk(file_path, byte_offset, length)
    File.open(file_path, "rb") do |file|
      file.seek(byte_offset)
      if length
        file.read(length)
      else
        file.read
      end
    end
  end
end

# 使用示例
def main()
  # 从JSON文件读取配置
  config ||= load_config_from_json("iap_config.json")
  prices ||= config[:prices]

  # 初始化API客户端
  api = AppStoreConnectAPI.new(config[:key_id], config[:issuer_id], config[:product_id_prefix])

  puts "🚀 开始批量创建内购项..."
  puts "📋 金额数组: $#{prices.join(", ")}"

  begin
    # 批量创建内购项
    results = api.create_batch_in_app_purchases(config[:app_id], prices)

    puts "\n🎉 内购项创建完成！"
    puts "📊 结果统计:"

    success_count = results.count { |r| r[:status] == "success" }
    failed_count = results.count { |r| r[:status] == "failed" }

    puts "✅ 成功: #{success_count} 个"
    puts "❌ 失败: #{failed_count} 个"

    results.each do |result|
      if result[:status] == "success"
        puts "  - $#{result[:price]}: #{result[:product_id]} (ID: #{result[:iap_id]})"
        if result[:price_point_id]
          puts "    价格档位ID: #{result[:price_point_id]}"
        end
        puts "    📸 截图ID: #{result[:screenshot_id]}"
      else
        puts "  - $#{result[:price]}: 失败 - #{result[:error]}"
      end
    end

    puts "\n📍 请在App Store Connect中完成最终审核提交"
  rescue => e
    puts "❌ 操作失败: #{e.message}"
    puts e.backtrace if $DEBUG
  end
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
  puts "App Store Connect API - 内购项批量创建工具"
  puts ""

  main()
end

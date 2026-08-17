# App Store 内购创建脚本

## 功能实现情况

- [x] 基本信息
- [x] 销售范围
- [x] 定价
- [x] 本地化信息
- [x] 审核截图
- [x] API失败自动重试

## 使用方法

1. 在appstoreconnect.apple.com - Users And Access - Integrations - App Store Connect API创建一个权限为`App Manager`的Team Keys，下载私钥文件(.p8)并放在脚本同目录下
2. 在`iap_config.json`和`iap_products.csv`配置文件里填写内购项相关信息
3. 将审核截图放在目录里
4. 执行命令`swift create_iap.swift`

## 注意

1. 内购项的Type固定为`Consumable`，Localization固定为美国英语`en-US`
2. csv中的`Price`列应该填写美金金额，例如金额是`$0.99`则填`0.99`
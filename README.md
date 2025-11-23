# App Store 内购创建脚本

## 功能实现情况

- [x] 基本信息
- [x] 销售范围
- [x] 定价
- [x] 本地化信息
- [x] 审核截图

## 使用方法

1. 在`iap_config.json`配置文件填写内购项相关信息
2. 将权限为`App管理`的私钥文件(.p8)放在脚本同目录下
3. 将审核截图放在目录里，重命名为`review.png`
4. 执行命令`./main.sh`或`sh ./main.sh`

## 注意

1. `iap_config.json`中的`product_id_prefix`应该填写内购ID的前缀
2. `iap_config.json`中的`prices`应该填写美金金额数组
3. 内购项的内购ID最终由前缀与美金金额组成，例如前缀是`com.ios.`，金额是[0.99, 1.99]，那么这两个内购项的ID就是`com.ios.0.99`和`com.ios.1.99`
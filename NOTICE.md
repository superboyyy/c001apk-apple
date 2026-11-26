# 第三方声明

- **c001apk**（[TG-Twilight/c001apk](https://github.com/TG-Twilight/c001apk)，GNU AGPL v3）：本项目的协议实现（请求签名、请求头、会话与人机验证流程、接口参数、链接解析、数盟设备标识获取与导入等）移植自该项目的 Flutter 客户端；表情图片与表情名称映射也来自该项目。其上游为 [bggRGjQaUbCoE/c001apk-flutter](https://github.com/bggRGjQaUbCoE/c001apk-flutter)。
- **szlm_res**（[kongwufang/szlm_res](https://github.com/kongwufang/szlm_res)，MIT）：数盟设备标识的字段编解码、报文构造与响应解密经上游 c001apk 移植自该项目（字段置换与校验和算法署名 People-11）。
- **coolapk-desktop**（[daimiaopeng/coolapk-desktop](https://github.com/daimiaopeng/coolapk-desktop)，MIT）：请求签名所用的查表数据源自该项目；实况图片视频地址的解析方式（`/v6/livePhoto/showVideo`）也参考了该项目。

酷安名称、商标及服务内容归相应权利人所有。

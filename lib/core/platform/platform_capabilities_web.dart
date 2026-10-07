/// 浏览器（Flutter web）。见 `platform_capabilities.dart`。
library;

/// 是否运行在浏览器里。
const bool isWebPlatform = true;

/// 浏览器不给 WebSocket 自定义请求头，Basic 凭据只能由**浏览器自己**代管。
///
/// 为什么这一点会直接影响"要不要试设备直连地址"：直连地址（`192.168.x.x:8000`）与
/// 服务端入口**不是同一个 origin**，浏览器会为它**单独**弹一次登录框；
/// 而公网入口下那些内网地址本来就不可达 —— 于是每试一个候选就白弹一次框、
/// 用户看到的就是"每次点击都要 basic auth"。
///
/// 所以 web 端**只走服务端代理地址**（与页面同源的那一个 realm），
/// 一次挑战之后浏览器会把凭据缓存到该 realm，后续（含 WebSocket 握手）自动带上。
const String browserAuthHint =
    '浏览器不允许 WebSocket 携带自定义请求头，Basic 凭据由浏览器代管：'
    '请在弹出的登录框里输入服务端账号密码（建议勾选「记住密码」），一次即可。';

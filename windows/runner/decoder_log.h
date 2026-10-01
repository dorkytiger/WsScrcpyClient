#ifndef RUNNER_DECODER_LOG_H_
#define RUNNER_DECODER_LOG_H_

#include <string>

// Windows 原生解码链路的统一日志出口（解码器 / 像素缓冲 / 窗口通道共用）。
//
// 为什么单独抽成一个编译单元：
//  1) 日志**必须落文件**（runner 是 GUI 子系统程序，`flutter run` 对它的 stderr 转发
//     并不保证可见，实机首跑就是"控制台什么都没有"），文件句柄与轮转逻辑只能有一份；
//  2) FlutterWindow（platform thread）与 ScrcpyVideoDecoder（解码线程）都要打日志，
//     如果各自持有一份句柄/基准时间，"相对首次写日志的耗时"就对不上了；
//  3) 用同一个 File 句柄写日志必须是**串行**的，否则交错/撕裂的行没法读。
//
// 每条日志的格式（用户明确要求"要有时间戳"，含壁钟毫秒 + 相对首次写日志的耗时）：
//   [2026-02-01 12:34:56.789 | +12345ms | pid=12345] <模块名>: <正文>
//
// 为什么带 pid：日志文件是**追加**写的，IDE 反复运行时多个实例的记录会混在一起；
// 没有 pid 就容易把"上一个实例的收尾"误读成"本实例里先销毁后创建"（真踩过）。
//
// 输出三条通路：
//   - OutputDebugStringA（调试器 / DebugView 可见）；
//   - stderr（`flutter run` 的控制台能转发出来）；
//   - 文件（**每条 flush**：进程崩了也要留下最后一条面包屑）。
//
// 文件路径：exe 同目录的 `scrcpy_decoder.log`；写不进去退 `%TEMP%\scrcpy_decoder.log`；
// 都失败就只走前两条通路。单个文件上限 2 MB，超过就地截断重开（长时间投流不会写爆盘）。

namespace ws_scrcpy {

// 初始化（幂等，可重复调用）：解析日志文件路径、取好句柄、打一条启动横幅。
//
// [module_name] 会出现在每条日志的前缀里，好区分是谁写的。
// 返回实际使用的日志文件路径；没有可用文件时返回空串。
const std::string& InitializeLog(const char* module_name);

// 把日志文件强行指到 [path]（"a" 或 "ab" 追加模式）。
//
// 只给本机自测用：自测要在一个干净的临时目录里验证"日志真的会被创建、真的会
// flush 落盘、超过 2 MB 真的会截断"，不能污染 exe 同目录。
// 必须在首次 DebugLog / InitializeLog **之前**调用。
void OverrideLogFilePathForTesting(const std::string& path);

// 写一条日志（自动补时间戳前缀 + 换行）。可多线程调用（内部串行）。
void DebugLog(const std::string& message);

// 同一 key 只输出第一次（用于"第一帧""引擎已取走"这类只关心有无的事件）。
bool LogOnce(const char* key, const std::string& message);

// 相对"模块首次写日志"的毫秒数；没写过日志时返回 -1。
long long LogElapsedMs();

// 当前实际使用的日志文件路径（可能是 `%TEMP%` 下的兜底路径，也可能是空串）。
std::string LogFilePath();

}  // namespace ws_scrcpy

#endif  // RUNNER_DECODER_LOG_H_

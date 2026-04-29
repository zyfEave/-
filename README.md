# 小象

小象是一个 Magisk / KernelSU / APatch WebUI root 模块，用于按计划重启微信和抖音，减少长期后台运行后的推送、前台启动或进程状态异常问题。

它不是普通 Android App，没有 AndroidManifest、Foreground Service、WorkManager 或 AlarmManager 主链路。模块依赖 root 模块脚本和 native daemon 工作。

## 功能

- WebUI 配置微信、抖音是否参与定时重启。
- 支持每天定点和固定间隔两种定时策略。
- 使用 native `timerfd + epoll + eventfd + 最小堆` 调度任务。
- 使用 supervisor 守护 native daemon，异常退出后按退避策略自动拉起。
- worker 通过 `/system/bin/sh script/run_task.sh` 执行实际重启流程。
- WebUI 可查看 supervisor、native、worker、clock、WakeLock、漂移和日志状态。
- WebUI 内置任务趋势图，从日志中解析 drift、duration、WakeLock heldMs 和 missedCount。
- 开机保护期内跳过息屏命令，避免刚开机卡在首屏时被直接熄屏。

## 主链路

```text
service.sh
  -> script/supervisor.sh
      -> bin/autofire_timed
          -> fork worker
              -> /system/bin/sh script/run_task.sh
```

核心目标是让空闲时 CPU 占用接近 0：

- 只有一个 scheduler daemon。
- 只有一个 `timerfd`。
- 只有一个 `epoll fd`。
- 只有一个 `eventfd` 用于 reload / signal wake。
- 所有任务由最小堆管理，只把最近 deadline arm 到 `timerfd`。
- worker 并发默认限制为 1，同一任务重叠时使用 pending-once 合并策略。

## WebUI

`webroot/index.html` 是单文件离线 WebUI，不依赖 CDN、Vue、React、Tailwind、外部字体或远程资源。

WebUI 调用接口：

```sh
sh "$MOD/script/config.sh" get-json
sh "$MOD/script/config.sh" save ...
sh "$MOD/script/config.sh" defaults
sh "$MOD/script/config.sh" doctor
sh "$MOD/script/config.sh" log 180
sh "$MOD/script/config.sh" clear-log
sh "$MOD/script/scheduler.sh" start
sh "$MOD/script/scheduler.sh" stop
sh "$MOD/script/scheduler.sh" restart
sh "$MOD/script/scheduler.sh" reload
sh "$MOD/script/scheduler.sh" status
"$MOD/bin/autofire_timed" --version
```

WebUI 会优先从当前 `/webroot/` 路径推导模块根目录，fallback 到：

```text
/data/adb/modules/autofire-app-restarter
/data/adb/modules_update/autofire-app-restarter
```

## 配置与状态

默认数据目录：

```text
/data/adb/autofire-app-restarter
```

常见文件：

```text
config/autofire.conf
logs/autofire.log
state/autofire.schedule
state/last_result
state/last_worker_exit
state/selected_clock
```

运行态 pid/lock 文件位于模块目录：

```text
run/autofire_supervisor.pid
run/autofire_timed.pid
run/supervisor.lock
run/stop
```

## 构建 native

需要 Android NDK：

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk
export HOST_TAG=linux-x86_64
sh native/build-android.sh
```

默认构建：

- `bin/autofire_timed`：arm64-v8a
- `bin/autofire_timed_armeabi-v7a`：armeabi-v7a

构建后必须验证：

```sh
bin/autofire_timed --version
strings bin/autofire_timed | grep XiaoXiangScheduler
strings bin/autofire_timed | grep timerfd_epoll_eventfd_heap
```

## 实机验证

不要使用 `/data/adb/modules/*` 通配符。使用明确模块路径：

```sh
MOD=/data/adb/modules/autofire-app-restarter

adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; ls -l "$MOD/webroot/index.html"'
adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; "$MOD/bin/autofire_timed" --version'
adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; sh "$MOD/script/config.sh" doctor'
adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; sh "$MOD/script/scheduler.sh" status'
adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; sh "$MOD/script/scheduler.sh" reload'
```

supervisor 验证：

```sh
adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; sh "$MOD/script/scheduler.sh" restart'
adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; PID=$(cat "$MOD/run/autofire_timed.pid"); tr "\0" " " < "/proc/$PID/cmdline"'
adb shell su -c 'MOD=/data/adb/modules/autofire-app-restarter; PID=$(cat "$MOD/run/autofire_timed.pid"); kill -9 "$PID"; sleep 8; sh "$MOD/script/scheduler.sh" status'
```

Doze / suspend 近似验证：

```sh
adb shell dumpsys battery unplug
adb shell dumpsys deviceidle force-idle
adb shell su -c 'logcat -s XiaoXiangScheduler'
adb shell dumpsys deviceidle unforce
adb shell dumpsys battery reset
```

## 注意事项

- 普通 `timerfd` 不能绕过 Android deep sleep；只有具备 `CAP_WAKE_ALARM` 且 `CLOCK_BOOTTIME_ALARM` 可用时，timer 才可能具备主动唤醒能力。
- root 不等于一定具备 `CAP_WAKE_ALARM`，请以启动日志和 `doctor` 输出为准。
- 厂商省电策略、用户手动限制后台、系统安全锁屏等行为不可完全由模块保证。
- 模块不会使用 cpuset、cgroup 或 CPU 绑核作为保活机制。
- 模块不会恢复 `while true + sleep 60` 轮询作为定时主链路。
- WakeLock 只在 dispatch 或任务执行窗口短暂持有，并带 timeout 兜底。

## 发布

发布前确认：

```sh
git status --short
git diff --check
```

版本号需要同步更新：

- `module.prop`
- `update.json`
- `changelog.md`

发布 zip 名称建议与 `update.json` 保持一致，例如：

```text
XiaoXiang-v3.2.zip
```

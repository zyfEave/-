#define _GNU_SOURCE

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef CLOCK_BOOTTIME
#define CLOCK_BOOTTIME 7
#endif

#ifndef CLOCK_BOOTTIME_ALARM
#define CLOCK_BOOTTIME_ALARM 9
#endif

#ifndef TFD_CLOEXEC
#define TFD_CLOEXEC 02000000
#endif

#ifndef TFD_NONBLOCK
#define TFD_NONBLOCK O_NONBLOCK
#endif

#ifndef TFD_TIMER_ABSTIME
#define TFD_TIMER_ABSTIME 1
#endif

#ifndef EFD_CLOEXEC
#define EFD_CLOEXEC O_CLOEXEC
#endif

#ifndef EFD_NONBLOCK
#define EFD_NONBLOCK O_NONBLOCK
#endif

#define LOG_TAG "XiaoXiangScheduler"
#define SCHEDULER_VERSION "2.6-native2"
#define SCHEDULER_ARCH "timerfd_epoll_eventfd_heap"

#if defined(__aarch64__)
#define SCHEDULER_ABI "arm64-v8a"
#elif defined(__arm__)
#define SCHEDULER_ABI "armeabi-v7a"
#elif defined(__x86_64__)
#define SCHEDULER_ABI "x86_64"
#elif defined(__i386__)
#define SCHEDULER_ABI "x86"
#else
#define SCHEDULER_ABI "unknown"
#endif

#define MAX_TASKS 64
#define MAX_HEAP_NODES (MAX_TASKS * 4)
#define MAX_WORKERS 1
#define MAX_READY_QUEUE 64
#define LINE_SIZE 512
#define SOURCE_SIZE 128
#define PATH_SIZE 512
#define STATE_VALUE_SIZE 256
#define NS_PER_SEC 1000000000LL
#define CAP_WAKE_ALARM_BIT 35
#define DISPATCH_WAKE_LOCK_NAME "xiaoxiang_dispatch_wake_lock"
#define DISPATCH_WAKE_LOCK_TIMEOUT_NS "5000000000"

typedef enum {
  TASK_DAILY = 1,
  TASK_INTERVAL = 2
} task_type_t;

typedef struct {
  task_type_t type;
  int task_id;
  uint64_t generation;
  int cancelled;
  int hour;
  int minute;
  int interval_sec;
  int64_t deadline_ns;
  time_t scheduled_wall_epoch;
  char source[SOURCE_SIZE];
} task_t;

typedef struct {
  int64_t deadline_ns;
  int task_index;
  int task_id;
  uint64_t generation;
} heap_node_t;

typedef struct {
  int task_id;
  uint64_t generation;
  int64_t deadline_ns;
  time_t scheduled_wall_epoch;
  time_t fired_wall_epoch;
  char source[SOURCE_SIZE];
} execution_t;

typedef struct {
  int active;
  pid_t pid;
  execution_t execution;
  int64_t started_ns;
  time_t started_wall_epoch;
} worker_t;

typedef struct {
  task_t tasks[MAX_TASKS];
  int task_count;
  heap_node_t heap[MAX_HEAP_NODES];
  int heap_size;
  uint64_t generation;
  int next_task_id;

  worker_t workers[MAX_WORKERS];
  execution_t ready_queue[MAX_READY_QUEUE];
  int ready_count;

  int timer_fd;
  int epoll_fd;
  int event_fd;
  clockid_t now_clock_id;
  const char *clock_name;
  int wake_capable;
  int suspend_aware;
  int has_cap_wake_alarm;
  int running;
} scheduler_t;

static char g_moddir[PATH_SIZE];
static char g_data_dir[PATH_SIZE];
static char g_state_dir[PATH_SIZE];
static char g_schedule_file[PATH_SIZE];
static char g_log_file[PATH_SIZE];
static int g_event_fd = -1;
static volatile sig_atomic_t g_reload_requested = 0;
static volatile sig_atomic_t g_stop_requested = 0;
static volatile sig_atomic_t g_sigchld_requested = 0;

static const char *bool_str(int value) {
  return value ? "true" : "false";
}

static void print_version(FILE *out) {
  fprintf(out,
          "XiaoXiangScheduler version=%s build=\"%s %s\" abi=%s arch=%s\n",
          SCHEDULER_VERSION,
          __DATE__,
          __TIME__,
          SCHEDULER_ABI,
          SCHEDULER_ARCH);
}

static int android_priority(const char *level) {
  if (strcmp(level, "ERROR") == 0) return ANDROID_LOG_ERROR;
  if (strcmp(level, "WARN") == 0) return ANDROID_LOG_WARN;
  if (strcmp(level, "DEBUG") == 0) return ANDROID_LOG_DEBUG;
  return ANDROID_LOG_INFO;
}

static void log_line(const char *level, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  va_list file_ap;
  va_copy(file_ap, ap);
  __android_log_vprint(android_priority(level), LOG_TAG, fmt, ap);
  va_end(ap);

  FILE *fp = fopen(g_log_file, "a");
  if (fp) {
    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    char time_buf[32];
    strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M:%S", &tm_now);

    fprintf(fp, "%s [%s] ", time_buf, level);
    vfprintf(fp, fmt, file_ap);
    fprintf(fp, "\n");
    fclose(fp);
  }

  va_end(file_ap);
}

static void write_state_value(const char *key, const char *value) {
  char path[PATH_SIZE];
  int written = snprintf(path, sizeof(path), "%s/%s", g_state_dir, key);
  if (written < 0 || (size_t)written >= sizeof(path)) return;

  FILE *fp = fopen(path, "w");
  if (!fp) return;
  fprintf(fp, "%s\n", value);
  fclose(fp);
}

static void write_state_ll(const char *key, long long value) {
  char buf[STATE_VALUE_SIZE];
  snprintf(buf, sizeof(buf), "%lld", value);
  write_state_value(key, buf);
}

static void trim_newline(char *s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ' || s[len - 1] == '\t')) {
    s[len - 1] = '\0';
    len--;
  }
}

static void format_wall_time(time_t epoch, char *buf, size_t size) {
  struct tm tm_value;
  localtime_r(&epoch, &tm_value);
  strftime(buf, size, "%Y-%m-%d %H:%M:%S", &tm_value);
}

static int64_t now_ns(clockid_t clock_id) {
  struct timespec ts;
  if (clock_gettime(clock_id, &ts) != 0) {
    log_line("ERROR", "clock_gettime失败：%s", strerror(errno));
    return 0;
  }
  return ((int64_t)ts.tv_sec * NS_PER_SEC) + ts.tv_nsec;
}

static time_t next_daily_epoch(time_t now, int hour, int minute) {
  struct tm tm_due;
  localtime_r(&now, &tm_due);
  tm_due.tm_hour = hour;
  tm_due.tm_min = minute;
  tm_due.tm_sec = 0;
  time_t due = mktime(&tm_due);
  if (due <= now) {
    due += 24 * 60 * 60;
  }
  return due;
}

static int parse_time_hhmm(const char *value, int *hour, int *minute) {
  int h = -1;
  int m = -1;
  char tail = 0;
  if (sscanf(value, "%d:%d%c", &h, &m, &tail) != 2) return 0;
  if (h < 0 || h > 23 || m < 0 || m > 59) return 0;
  *hour = h;
  *minute = m;
  return 1;
}

static int heap_less(const heap_node_t *a, const heap_node_t *b) {
  if (a->deadline_ns != b->deadline_ns) return a->deadline_ns < b->deadline_ns;
  return a->task_id < b->task_id;
}

static void heap_swap(heap_node_t *a, heap_node_t *b) {
  heap_node_t tmp = *a;
  *a = *b;
  *b = tmp;
}

static int heap_push(scheduler_t *scheduler, heap_node_t node) {
  if (scheduler->heap_size >= MAX_HEAP_NODES) {
    log_line("ERROR", "任务堆已满：taskId=%d, queueSize=%d", node.task_id, scheduler->heap_size);
    return -1;
  }

  int index = scheduler->heap_size++;
  scheduler->heap[index] = node;
  while (index > 0) {
    int parent = (index - 1) / 2;
    if (!heap_less(&scheduler->heap[index], &scheduler->heap[parent])) break;
    heap_swap(&scheduler->heap[index], &scheduler->heap[parent]);
    index = parent;
  }
  return 0;
}

static heap_node_t heap_pop(scheduler_t *scheduler) {
  heap_node_t result;
  memset(&result, 0, sizeof(result));
  if (scheduler->heap_size <= 0) return result;

  result = scheduler->heap[0];
  scheduler->heap_size--;
  if (scheduler->heap_size > 0) {
    scheduler->heap[0] = scheduler->heap[scheduler->heap_size];
    int index = 0;
    while (1) {
      int left = index * 2 + 1;
      int right = left + 1;
      int smallest = index;
      if (left < scheduler->heap_size && heap_less(&scheduler->heap[left], &scheduler->heap[smallest])) {
        smallest = left;
      }
      if (right < scheduler->heap_size && heap_less(&scheduler->heap[right], &scheduler->heap[smallest])) {
        smallest = right;
      }
      if (smallest == index) break;
      heap_swap(&scheduler->heap[index], &scheduler->heap[smallest]);
      index = smallest;
    }
  }

  return result;
}

static const heap_node_t *heap_peek(const scheduler_t *scheduler) {
  if (scheduler->heap_size <= 0) return NULL;
  return &scheduler->heap[0];
}

static void compute_first_deadline(task_t *task, time_t wall_now, int64_t clock_now_ns) {
  if (task->type == TASK_DAILY) {
    task->scheduled_wall_epoch = next_daily_epoch(wall_now, task->hour, task->minute);
    int64_t delay_sec = (int64_t)(task->scheduled_wall_epoch - wall_now);
    if (delay_sec < 1) delay_sec = 1;
    task->deadline_ns = clock_now_ns + delay_sec * NS_PER_SEC;
  } else {
    task->scheduled_wall_epoch = wall_now + task->interval_sec;
    task->deadline_ns = clock_now_ns + (int64_t)task->interval_sec * NS_PER_SEC;
  }
}

static void reschedule_after_fire(task_t *task, time_t wall_now, int64_t clock_now_ns) {
  if (task->type == TASK_DAILY) {
    task->scheduled_wall_epoch = next_daily_epoch(wall_now, task->hour, task->minute);
    int64_t delay_sec = (int64_t)(task->scheduled_wall_epoch - wall_now);
    if (delay_sec < 1) delay_sec = 1;
    task->deadline_ns = clock_now_ns + delay_sec * NS_PER_SEC;
    return;
  }

  int64_t interval_ns = (int64_t)task->interval_sec * NS_PER_SEC;
  int64_t next_deadline = task->deadline_ns + interval_ns;
  if (next_deadline <= clock_now_ns) {
    int64_t elapsed = clock_now_ns - task->deadline_ns;
    int64_t periods = elapsed / interval_ns + 1;
    next_deadline = task->deadline_ns + periods * interval_ns;
  }
  task->deadline_ns = next_deadline;
  task->scheduled_wall_epoch = wall_now + (time_t)((next_deadline - clock_now_ns) / NS_PER_SEC);
}

static unsigned long long compute_missed_count(const task_t *task, time_t wall_now, int64_t clock_now_ns) {
  if (task->type == TASK_INTERVAL) {
    int64_t interval_ns = (int64_t)task->interval_sec * NS_PER_SEC;
    if (clock_now_ns <= task->deadline_ns || interval_ns <= 0) return 0;
    int64_t due_count = (clock_now_ns - task->deadline_ns) / interval_ns + 1;
    return due_count > 1 ? (unsigned long long)(due_count - 1) : 0;
  }

  if (wall_now <= task->scheduled_wall_epoch) return 0;
  time_t late_sec = wall_now - task->scheduled_wall_epoch;
  return late_sec >= 24 * 60 * 60 ? (unsigned long long)(late_sec / (24 * 60 * 60)) : 0;
}

static int push_task_deadline(scheduler_t *scheduler, int task_index) {
  task_t *task = &scheduler->tasks[task_index];
  heap_node_t node;
  memset(&node, 0, sizeof(node));
  node.deadline_ns = task->deadline_ns;
  node.task_index = task_index;
  node.task_id = task->task_id;
  node.generation = task->generation;
  return heap_push(scheduler, node);
}

static int parse_jobs_into(scheduler_t *target, char *error_buf, size_t error_size) {
  FILE *fp = fopen(g_schedule_file, "r");
  if (!fp) {
    snprintf(error_buf, error_size, "open schedule failed errno=%d error=%s", errno, strerror(errno));
    return -1;
  }

  target->task_count = 0;
  target->heap_size = 0;
  target->generation++;

  char line[LINE_SIZE];
  int line_no = 0;
  time_t wall_now = time(NULL);
  int64_t clock_now_ns = now_ns(target->now_clock_id);

  while (fgets(line, sizeof(line), fp)) {
    line_no++;
    if (target->task_count >= MAX_TASKS) {
      snprintf(error_buf, error_size, "too many tasks line=%d max=%d", line_no, MAX_TASKS);
      fclose(fp);
      return -1;
    }

    trim_newline(line);
    if (line[0] == '\0' || line[0] == '#') continue;

    char raw_line[LINE_SIZE];
    snprintf(raw_line, sizeof(raw_line), "%s", line);

    char *type = strtok(line, "|");
    char *value = strtok(NULL, "|");
    char *source = strtok(NULL, "|");
    if (!type || !value || !source) {
      snprintf(error_buf, error_size, "invalid schedule line=%d content=%s", line_no, raw_line);
      fclose(fp);
      return -1;
    }

    task_t *task = &target->tasks[target->task_count];
    memset(task, 0, sizeof(*task));
    task->task_id = target->next_task_id++;
    if (target->next_task_id <= 0) target->next_task_id = 1;
    task->generation = target->generation;
    snprintf(task->source, sizeof(task->source), "%s", source);

    if (strcmp(type, "daily") == 0) {
      if (!parse_time_hhmm(value, &task->hour, &task->minute)) {
        snprintf(error_buf, error_size, "invalid daily time line=%d value=%s", line_no, value);
        fclose(fp);
        return -1;
      }
      task->type = TASK_DAILY;
    } else if (strcmp(type, "interval") == 0) {
      char *end = NULL;
      long minutes = strtol(value, &end, 10);
      if (!end || *end != '\0' || minutes < 1 || minutes > 1440) {
        snprintf(error_buf, error_size, "invalid interval line=%d value=%s", line_no, value);
        fclose(fp);
        return -1;
      }
      task->type = TASK_INTERVAL;
      task->interval_sec = (int)(minutes * 60);
    } else {
      snprintf(error_buf, error_size, "unknown schedule type line=%d type=%s", line_no, type);
      fclose(fp);
      return -1;
    }

    compute_first_deadline(task, wall_now, clock_now_ns);
    int task_index = target->task_count;
    if (push_task_deadline(target, task_index) != 0) {
      snprintf(error_buf, error_size, "heap push failed line=%d", line_no);
      fclose(fp);
      return -1;
    }

    char deadline_buf[32];
    format_wall_time(task->scheduled_wall_epoch, deadline_buf, sizeof(deadline_buf));
    log_line("INFO",
             "任务入队：taskId=%d, source=%s, deadline=%s, interval=%d, generation=%llu, queueSize=%d",
             task->task_id,
             task->source,
             deadline_buf,
             task->interval_sec,
             (unsigned long long)task->generation,
             target->heap_size);
    target->task_count++;
  }

  fclose(fp);
  if (target->task_count <= 0) {
    snprintf(error_buf, error_size, "schedule has no valid task");
    return -1;
  }
  return target->task_count;
}

static int reload_jobs_atomic(scheduler_t *scheduler, int initial_load) {
  scheduler_t candidate = *scheduler;
  candidate.task_count = 0;
  candidate.heap_size = 0;

  char error_buf[STATE_VALUE_SIZE];
  error_buf[0] = '\0';
  int count = parse_jobs_into(&candidate, error_buf, sizeof(error_buf));
  if (count < 0) {
    log_line(initial_load ? "ERROR" : "WARN",
             "定时表加载失败，保留旧任务：%s, schedule=%s",
             error_buf,
             g_schedule_file);
    write_state_value("last_reload_error", error_buf);
    return -1;
  }

  int old_ready_count = scheduler->ready_count;
  task_t old_tasks[MAX_TASKS];
  heap_node_t old_heap[MAX_HEAP_NODES];
  memcpy(old_tasks, candidate.tasks, sizeof(old_tasks));
  memcpy(old_heap, candidate.heap, sizeof(old_heap));

  memcpy(scheduler->tasks, old_tasks, sizeof(scheduler->tasks));
  memcpy(scheduler->heap, old_heap, sizeof(scheduler->heap));
  scheduler->task_count = candidate.task_count;
  scheduler->heap_size = candidate.heap_size;
  scheduler->generation = candidate.generation;
  scheduler->next_task_id = candidate.next_task_id;
  scheduler->ready_count = 0;

  if (old_ready_count > 0) {
    log_line("WARN", "workerDropStale reason=reload oldReadyCount=%d policy=pending_once", old_ready_count);
  }

  log_line("INFO",
           "定时表加载完成：taskCount=%d, queueSize=%d, generation=%llu",
           scheduler->task_count,
           scheduler->heap_size,
           (unsigned long long)scheduler->generation);
  write_state_value("last_reload_error", "");
  return count;
}

static unsigned long long read_cap_eff(void) {
  FILE *fp = fopen("/proc/self/status", "r");
  if (!fp) {
    log_line("WARN", "读取CapEff失败：%s", strerror(errno));
    return 0;
  }

  char line[LINE_SIZE];
  unsigned long long value = 0;
  while (fgets(line, sizeof(line), fp)) {
    if (strncmp(line, "CapEff:", 7) == 0) {
      char *p = line + 7;
      while (*p == ' ' || *p == '\t') p++;
      value = strtoull(p, NULL, 16);
      break;
    }
  }
  fclose(fp);
  return value;
}

static int has_cap_wake_alarm(void) {
  unsigned long long cap_eff = read_cap_eff();
  int has_cap = ((cap_eff >> CAP_WAKE_ALARM_BIT) & 1ULL) ? 1 : 0;
  log_line("INFO", "能力检查：CapEff=0x%llx, hasCapWakeAlarm=%s", cap_eff, bool_str(has_cap));
  write_state_value("wake_capable_cap", has_cap ? "1" : "0");
  return has_cap;
}

static int try_timerfd_clock(clockid_t clock_id, const char *clock_name) {
  int fd = timerfd_create(clock_id, TFD_CLOEXEC | TFD_NONBLOCK);
  if (fd < 0) {
    log_line("WARN",
             "timerfd_create失败：clockName=%s, errno=%d, error=%s",
             clock_name,
             errno,
             strerror(errno));
  }
  return fd;
}

static int create_timerfd_with_fallback(scheduler_t *scheduler) {
  scheduler->has_cap_wake_alarm = has_cap_wake_alarm();

  int fd = try_timerfd_clock(CLOCK_BOOTTIME_ALARM, "CLOCK_BOOTTIME_ALARM");
  if (fd >= 0) {
    scheduler->now_clock_id = CLOCK_BOOTTIME;
    scheduler->clock_name = "CLOCK_BOOTTIME_ALARM";
    scheduler->wake_capable = 1;
    scheduler->suspend_aware = 1;
    return fd;
  }

  fd = try_timerfd_clock(CLOCK_BOOTTIME, "CLOCK_BOOTTIME");
  if (fd >= 0) {
    scheduler->now_clock_id = CLOCK_BOOTTIME;
    scheduler->clock_name = "CLOCK_BOOTTIME";
    scheduler->wake_capable = 0;
    scheduler->suspend_aware = 1;
    log_line("WARN", "selectedClock=CLOCK_BOOTTIME: deep sleep may delay scheduled tasks; timerfd will not wake the device");
    return fd;
  }

  fd = try_timerfd_clock(CLOCK_MONOTONIC, "CLOCK_MONOTONIC");
  if (fd >= 0) {
    scheduler->now_clock_id = CLOCK_MONOTONIC;
    scheduler->clock_name = "CLOCK_MONOTONIC";
    scheduler->wake_capable = 0;
    scheduler->suspend_aware = 0;
    log_line("WARN", "selectedClock=CLOCK_MONOTONIC: deep sleep may delay scheduled tasks; timerfd will not wake the device");
    return fd;
  }

  log_line("ERROR", "timerfd创建失败：所有clock均不可用");
  return -1;
}

static void publish_clock_state(const scheduler_t *scheduler) {
  write_state_value("native_version", SCHEDULER_VERSION);
  write_state_value("selected_clock", scheduler->clock_name ? scheduler->clock_name : "unknown");
  write_state_value("wake_capable", scheduler->wake_capable ? "1" : "0");
  write_state_value("suspend_aware", scheduler->suspend_aware ? "1" : "0");
  log_line("INFO",
           "XiaoXiangScheduler version=%s build=\"%s %s\" abi=%s arch=%s selectedClock=%s wakeCapable=%s suspendAware=%s hasCapWakeAlarm=%s",
           SCHEDULER_VERSION,
           __DATE__,
           __TIME__,
           SCHEDULER_ABI,
           SCHEDULER_ARCH,
           scheduler->clock_name,
           bool_str(scheduler->wake_capable),
           bool_str(scheduler->suspend_aware),
           bool_str(scheduler->has_cap_wake_alarm));
}

static int disarm_timer(scheduler_t *scheduler) {
  struct itimerspec spec;
  memset(&spec, 0, sizeof(spec));
  int rc = timerfd_settime(scheduler->timer_fd, 0, &spec, NULL);
  if (rc != 0) {
    log_line("ERROR", "解除timerfd失败：%s", strerror(errno));
  } else {
    log_line("INFO", "timerfd已解除武装：queueSize=%d", scheduler->heap_size);
  }
  return rc;
}

static int arm_timer_from_heap(scheduler_t *scheduler) {
  const heap_node_t *next = heap_peek(scheduler);
  if (!next) {
    return disarm_timer(scheduler);
  }

  struct itimerspec spec;
  memset(&spec, 0, sizeof(spec));
  spec.it_value.tv_sec = (time_t)(next->deadline_ns / NS_PER_SEC);
  spec.it_value.tv_nsec = (long)(next->deadline_ns % NS_PER_SEC);

  int rc = timerfd_settime(scheduler->timer_fd, TFD_TIMER_ABSTIME, &spec, NULL);
  int64_t delay_ms = (next->deadline_ns - now_ns(scheduler->now_clock_id)) / 1000000LL;
  if (delay_ms < 0) delay_ms = 0;

  if (rc != 0) {
    log_line("ERROR", "设置timerfd失败：%s", strerror(errno));
  } else {
    log_line("INFO", "timerfd_settime：taskId=%d, selectedClock=%s, nextDeadlineNs=%lld, delayMs=%lld, queueSize=%d",
             next->task_id,
             scheduler->clock_name,
             (long long)next->deadline_ns,
             (long long)delay_ms,
             scheduler->heap_size);
  }
  return rc;
}

static uint64_t drain_fd_counter(int fd, const char *name) {
  uint64_t total = 0;
  while (1) {
    uint64_t value = 0;
    ssize_t n = read(fd, &value, sizeof(value));
    if (n == (ssize_t)sizeof(value)) {
      total += value;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    if (n == 0) break;
    if (n < 0) {
      log_line("WARN", "%s读取失败：%s", name, strerror(errno));
    } else {
      log_line("WARN", "%s读取长度异常：%zd", name, n);
    }
    break;
  }
  return total;
}

static int acquire_dispatch_wake_lock(void) {
  int fd = open("/sys/power/wake_lock", O_WRONLY | O_CLOEXEC);
  if (fd < 0) {
    log_line("WARN", "dispatch唤醒锁不可用：name=%s, errno=%d, error=%s",
             DISPATCH_WAKE_LOCK_NAME,
             errno,
             strerror(errno));
    return -1;
  }

  char value[128];
  int len = snprintf(value, sizeof(value), "%s %s", DISPATCH_WAKE_LOCK_NAME, DISPATCH_WAKE_LOCK_TIMEOUT_NS);
  ssize_t written = write(fd, value, (size_t)len);
  int saved_errno = errno;
  close(fd);

  if (written != len) {
    log_line("WARN", "dispatch唤醒锁获取失败：name=%s, timeoutNs=%s, errno=%d, error=%s",
             DISPATCH_WAKE_LOCK_NAME,
             DISPATCH_WAKE_LOCK_TIMEOUT_NS,
             saved_errno,
             strerror(saved_errno));
    return -1;
  }

  log_line("INFO", "dispatch唤醒锁已获取：name=%s, timeoutNs=%s", DISPATCH_WAKE_LOCK_NAME, DISPATCH_WAKE_LOCK_TIMEOUT_NS);
  return 0;
}

static int active_worker_count(const scheduler_t *scheduler) {
  int count = 0;
  for (int i = 0; i < MAX_WORKERS; i++) {
    if (scheduler->workers[i].active) count++;
  }
  return count;
}

static int source_active(const scheduler_t *scheduler, const char *source, int task_id) {
  for (int i = 0; i < MAX_WORKERS; i++) {
    if (!scheduler->workers[i].active) continue;
    if (scheduler->workers[i].execution.task_id == task_id) return 1;
    if (strcmp(scheduler->workers[i].execution.source, source) == 0) return 1;
  }
  return 0;
}

static int source_pending(const scheduler_t *scheduler, const char *source, int task_id) {
  for (int i = 0; i < scheduler->ready_count; i++) {
    if (scheduler->ready_queue[i].task_id == task_id) return 1;
    if (strcmp(scheduler->ready_queue[i].source, source) == 0) return 1;
  }
  return 0;
}

static int find_free_worker_slot(const scheduler_t *scheduler) {
  for (int i = 0; i < MAX_WORKERS; i++) {
    if (!scheduler->workers[i].active) return i;
  }
  return -1;
}

static void update_active_worker_state(const scheduler_t *scheduler) {
  write_state_ll("active_workers", active_worker_count(scheduler));
  write_state_ll("ready_workers", scheduler->ready_count);
}

static int start_worker_now(scheduler_t *scheduler, const execution_t *execution) {
  int slot = find_free_worker_slot(scheduler);
  if (slot < 0) return -1;

  char script_path[PATH_SIZE + 32];
  int written = snprintf(script_path, sizeof(script_path), "%s/script/run_task.sh", g_moddir);
  if (written < 0 || (size_t)written >= sizeof(script_path)) {
    log_line("ERROR", "任务脚本路径过长：taskId=%d", execution->task_id);
    return -1;
  }

  (void)acquire_dispatch_wake_lock();
  int64_t started_ns = now_ns(scheduler->now_clock_id);
  time_t started_wall = time(NULL);

  pid_t pid = fork();
  if (pid < 0) {
    log_line("ERROR", "workerStart失败：taskId=%d, source=%s, errno=%d, error=%s",
             execution->task_id,
             execution->source,
             errno,
             strerror(errno));
    return -1;
  }

  if (pid == 0) {
    execl("/system/bin/sh", "sh", script_path, execution->source, "0", (char *)NULL);
    _exit(127);
  }

  scheduler->workers[slot].active = 1;
  scheduler->workers[slot].pid = pid;
  scheduler->workers[slot].execution = *execution;
  scheduler->workers[slot].started_ns = started_ns;
  scheduler->workers[slot].started_wall_epoch = started_wall;
  update_active_worker_state(scheduler);

  char scheduled_buf[32];
  char fired_buf[32];
  char started_buf[32];
  format_wall_time(execution->scheduled_wall_epoch, scheduled_buf, sizeof(scheduled_buf));
  format_wall_time(execution->fired_wall_epoch, fired_buf, sizeof(fired_buf));
  format_wall_time(started_wall, started_buf, sizeof(started_buf));

  log_line("INFO",
           "workerStart：taskId=%d, generation=%llu, pid=%d, source=%s, deadlineNs=%lld, scheduledAt=%s, firedAt=%s, startedAt=%s, activeWorkers=%d, readyQueue=%d",
           execution->task_id,
           (unsigned long long)execution->generation,
           pid,
           execution->source,
           (long long)execution->deadline_ns,
           scheduled_buf,
           fired_buf,
           started_buf,
           active_worker_count(scheduler),
           scheduler->ready_count);
  return 0;
}

static int enqueue_ready(scheduler_t *scheduler, const execution_t *execution) {
  if (scheduler->ready_count >= MAX_READY_QUEUE) {
    log_line("ERROR", "ready队列已满，任务跳过：taskId=%d, source=%s, readyQueue=%d",
             execution->task_id,
             execution->source,
             scheduler->ready_count);
    return -1;
  }

  scheduler->ready_queue[scheduler->ready_count++] = *execution;
  update_active_worker_state(scheduler);
  log_line("INFO",
           "workerQueued：taskId=%d, source=%s, activeWorkers=%d, readyQueue=%d",
           execution->task_id,
           execution->source,
           active_worker_count(scheduler),
           scheduler->ready_count);
  return 0;
}

static void start_ready_workers(scheduler_t *scheduler) {
  while (scheduler->ready_count > 0 && active_worker_count(scheduler) < MAX_WORKERS) {
    execution_t execution = scheduler->ready_queue[0];
    for (int i = 1; i < scheduler->ready_count; i++) {
      scheduler->ready_queue[i - 1] = scheduler->ready_queue[i];
    }
    scheduler->ready_count--;

    if (source_active(scheduler, execution.source, execution.task_id)) {
      log_line("WARN",
               "workerCoalesce policy=pending_once action=still_running taskId=%d source=%s",
               execution.task_id,
               execution.source);
      continue;
    }

    if (start_worker_now(scheduler, &execution) != 0) {
      (void)enqueue_ready(scheduler, &execution);
      break;
    }
  }
  update_active_worker_state(scheduler);
}

static void submit_execution(scheduler_t *scheduler, const execution_t *execution) {
  if (source_pending(scheduler, execution->source, execution->task_id)) {
    log_line("WARN",
             "workerCoalesce policy=pending_once action=already_pending taskId=%d source=%s",
             execution->task_id,
             execution->source);
    return;
  }

  if (source_active(scheduler, execution->source, execution->task_id)) {
    log_line("WARN",
             "workerCoalesce policy=pending_once action=queue_pending_once taskId=%d source=%s",
             execution->task_id,
             execution->source);
    (void)enqueue_ready(scheduler, execution);
    return;
  }

  if (active_worker_count(scheduler) < MAX_WORKERS) {
    if (start_worker_now(scheduler, execution) == 0) return;
  }

  (void)enqueue_ready(scheduler, execution);
}

static void reap_workers(scheduler_t *scheduler) {
  while (1) {
    int status = 0;
    pid_t pid = waitpid(-1, &status, WNOHANG);
    if (pid > 0) {
      int found = -1;
      for (int i = 0; i < MAX_WORKERS; i++) {
        if (scheduler->workers[i].active && scheduler->workers[i].pid == pid) {
          found = i;
          break;
        }
      }

      int exit_code = -1;
      int signal_no = 0;
      if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
      } else if (WIFSIGNALED(status)) {
        signal_no = WTERMSIG(status);
      }

      if (found >= 0) {
        worker_t *worker = &scheduler->workers[found];
        int64_t duration_ms = (now_ns(scheduler->now_clock_id) - worker->started_ns) / 1000000LL;
        if (duration_ms < 0) duration_ms = 0;

        log_line("INFO",
                 "workerExit：taskId=%d, generation=%llu, pid=%d, source=%s, deadlineNs=%lld, exitCode=%d, signal=%d, durationMs=%lld",
                 worker->execution.task_id,
                 (unsigned long long)worker->execution.generation,
                 pid,
                 worker->execution.source,
                 (long long)worker->execution.deadline_ns,
                 exit_code,
                 signal_no,
                 (long long)duration_ms);

        char state[STATE_VALUE_SIZE];
        snprintf(state,
                 sizeof(state),
                 "taskId=%d generation=%llu pid=%d source=%s deadlineNs=%lld exitCode=%d signal=%d durationMs=%lld",
                 worker->execution.task_id,
                 (unsigned long long)worker->execution.generation,
                 pid,
                 worker->execution.source,
                 (long long)worker->execution.deadline_ns,
                 exit_code,
                 signal_no,
                 (long long)duration_ms);
        write_state_value("last_worker_exit", state);
        memset(worker, 0, sizeof(*worker));
      } else {
        log_line("WARN", "收到未知worker退出：pid=%d, exitCode=%d, signal=%d", pid, exit_code, signal_no);
      }
      continue;
    }

    if (pid == 0) break;
    if (errno == EINTR) continue;
    if (errno != ECHILD) {
      log_line("WARN", "waitpid失败：errno=%d, error=%s", errno, strerror(errno));
    }
    break;
  }

  update_active_worker_state(scheduler);
  start_ready_workers(scheduler);
}

static void execution_from_task(execution_t *execution, const task_t *task, time_t fired_wall_epoch) {
  memset(execution, 0, sizeof(*execution));
  execution->task_id = task->task_id;
  execution->generation = task->generation;
  execution->deadline_ns = task->deadline_ns;
  execution->scheduled_wall_epoch = task->scheduled_wall_epoch;
  execution->fired_wall_epoch = fired_wall_epoch;
  snprintf(execution->source, sizeof(execution->source), "%s", task->source);
}

static void run_due_tasks(scheduler_t *scheduler, uint64_t timer_expirations) {
  int fired_count = 0;

  while (scheduler->heap_size > 0) {
    int64_t clock_now_ns = now_ns(scheduler->now_clock_id);
    const heap_node_t *peek = heap_peek(scheduler);
    if (!peek || peek->deadline_ns > clock_now_ns) break;

    heap_node_t node = heap_pop(scheduler);
    if (node.task_index < 0 || node.task_index >= scheduler->task_count) continue;

    task_t *task = &scheduler->tasks[node.task_index];
    if (task->cancelled || task->generation != node.generation || task->deadline_ns != node.deadline_ns) {
      log_line("DEBUG", "跳过已取消或过期任务：taskId=%d, generation=%llu",
               node.task_id,
               (unsigned long long)node.generation);
      continue;
    }

    time_t wall_now = time(NULL);
    int64_t drift_ms = (clock_now_ns - task->deadline_ns) / 1000000LL;
    if (drift_ms < 0) drift_ms = 0;
    unsigned long long missed_count = compute_missed_count(task, wall_now, clock_now_ns);

    char scheduled_buf[32];
    char fired_buf[32];
    format_wall_time(task->scheduled_wall_epoch, scheduled_buf, sizeof(scheduled_buf));
    format_wall_time(wall_now, fired_buf, sizeof(fired_buf));

    log_line("INFO",
             "任务触发：taskId=%d, source=%s, scheduledAt=%s, firedAt=%s, driftMs=%lld, missedCount=%llu, timerExpirations=%llu",
             task->task_id,
             task->source,
             scheduled_buf,
             fired_buf,
             (long long)drift_ms,
             missed_count,
             (unsigned long long)timer_expirations);
    write_state_ll("last_drift_ms", (long long)drift_ms);

    execution_t execution;
    execution_from_task(&execution, task, wall_now);
    submit_execution(scheduler, &execution);
    fired_count++;

    clock_now_ns = now_ns(scheduler->now_clock_id);
    wall_now = time(NULL);
    reschedule_after_fire(task, wall_now, clock_now_ns);
    if (!task->cancelled) {
      (void)push_task_deadline(scheduler, node.task_index);
    }
  }

  log_line("INFO",
           "到期任务批处理完成：firedCount=%d, queueSize=%d, activeWorkers=%d, readyQueue=%d",
           fired_count,
           scheduler->heap_size,
           active_worker_count(scheduler),
           scheduler->ready_count);
}

static void notify_event_fd(void) {
  int saved_errno = errno;
  if (g_event_fd >= 0) {
    uint64_t one = 1;
    ssize_t ignored = write(g_event_fd, &one, sizeof(one));
    (void)ignored;
  }
  errno = saved_errno;
}

static void handle_signal(int signum) {
  if (signum == SIGHUP) {
    g_reload_requested = 1;
  } else if (signum == SIGCHLD) {
    g_sigchld_requested = 1;
  } else {
    g_stop_requested = 1;
  }
  notify_event_fd();
}

static int install_signal_handlers(void) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = handle_signal;
  sigemptyset(&action.sa_mask);

  if (sigaction(SIGTERM, &action, NULL) != 0) return -1;
  if (sigaction(SIGINT, &action, NULL) != 0) return -1;
  if (sigaction(SIGHUP, &action, NULL) != 0) return -1;
  if (sigaction(SIGCHLD, &action, NULL) != 0) return -1;
  return 0;
}

static void handle_control_events(scheduler_t *scheduler) {
  (void)drain_fd_counter(scheduler->event_fd, "eventfd");

  if (g_sigchld_requested) {
    g_sigchld_requested = 0;
    reap_workers(scheduler);
  }

  if (g_reload_requested) {
    g_reload_requested = 0;
    log_line("INFO", "收到重载信号，重新读取定时表");
    if (reload_jobs_atomic(scheduler, 0) >= 0) {
      (void)arm_timer_from_heap(scheduler);
    }
  }

  if (g_stop_requested) {
    log_line("INFO", "收到退出信号，准备关闭native定时器");
    scheduler->running = 0;
  }
}

static int add_epoll_fd(int epoll_fd, int fd, uint32_t events) {
  struct epoll_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.events = events;
  ev.data.fd = fd;
  return epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd, &ev);
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    print_version(stdout);
    return 0;
  }

  if (argc < 5) {
    print_version(stderr);
    fprintf(stderr, "usage: %s MODDIR DATA_DIR SCHEDULE_FILE LOG_FILE\n", argv[0]);
    return 2;
  }

  snprintf(g_moddir, sizeof(g_moddir), "%s", argv[1]);
  snprintf(g_data_dir, sizeof(g_data_dir), "%s", argv[2]);
  snprintf(g_state_dir, sizeof(g_state_dir), "%s/state", argv[2]);
  snprintf(g_schedule_file, sizeof(g_schedule_file), "%s", argv[3]);
  snprintf(g_log_file, sizeof(g_log_file), "%s", argv[4]);

  scheduler_t scheduler;
  memset(&scheduler, 0, sizeof(scheduler));
  scheduler.timer_fd = -1;
  scheduler.epoll_fd = -1;
  scheduler.event_fd = -1;
  scheduler.next_task_id = 1;
  scheduler.running = 1;

  scheduler.timer_fd = create_timerfd_with_fallback(&scheduler);
  if (scheduler.timer_fd < 0) return 1;
  publish_clock_state(&scheduler);

  scheduler.event_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (scheduler.event_fd < 0) {
    log_line("ERROR", "eventfd创建失败：%s", strerror(errno));
    close(scheduler.timer_fd);
    return 1;
  }
  g_event_fd = scheduler.event_fd;

  if (install_signal_handlers() != 0) {
    log_line("ERROR", "信号处理安装失败：%s", strerror(errno));
    close(scheduler.event_fd);
    close(scheduler.timer_fd);
    return 1;
  }

  scheduler.epoll_fd = epoll_create1(EPOLL_CLOEXEC);
  if (scheduler.epoll_fd < 0) {
    log_line("ERROR", "epoll创建失败：%s", strerror(errno));
    close(scheduler.event_fd);
    close(scheduler.timer_fd);
    return 1;
  }

  if (add_epoll_fd(scheduler.epoll_fd, scheduler.timer_fd, EPOLLIN) != 0) {
    log_line("ERROR", "epoll注册timerfd失败：%s", strerror(errno));
    close(scheduler.epoll_fd);
    close(scheduler.event_fd);
    close(scheduler.timer_fd);
    return 1;
  }

  if (add_epoll_fd(scheduler.epoll_fd, scheduler.event_fd, EPOLLIN) != 0) {
    log_line("ERROR", "epoll注册eventfd失败：%s", strerror(errno));
    close(scheduler.epoll_fd);
    close(scheduler.event_fd);
    close(scheduler.timer_fd);
    return 1;
  }

  if (reload_jobs_atomic(&scheduler, 1) < 0) {
    (void)disarm_timer(&scheduler);
  } else {
    (void)arm_timer_from_heap(&scheduler);
  }
  write_state_value("worker_policy", "pending_once");
  update_active_worker_state(&scheduler);

  log_line("INFO",
           "native低开销定时器已进入等待：taskCount=%d, queueSize=%d, clock=%s, timerfd=1, epoll=1, eventfd=1, maxWorkers=%d, workerPolicy=pending_once",
           scheduler.task_count,
           scheduler.heap_size,
           scheduler.clock_name,
           MAX_WORKERS);

  while (scheduler.running) {
    struct epoll_event events[4];
    int n = epoll_wait(scheduler.epoll_fd, events, 4, -1);
    if (n < 0) {
      if (errno == EINTR) {
        handle_control_events(&scheduler);
        (void)arm_timer_from_heap(&scheduler);
        continue;
      }
      log_line("ERROR", "epoll等待失败：%s", strerror(errno));
      break;
    }

    uint64_t timer_expirations = 0;
    int saw_timer = 0;
    int saw_control = 0;

    for (int i = 0; i < n; i++) {
      if (events[i].data.fd == scheduler.timer_fd) {
        saw_timer = 1;
        timer_expirations += drain_fd_counter(scheduler.timer_fd, "timerfd");
      } else if (events[i].data.fd == scheduler.event_fd) {
        saw_control = 1;
      } else {
        log_line("WARN", "epoll收到未知fd事件：fd=%d, events=0x%x", events[i].data.fd, events[i].events);
      }
    }

    if (saw_control || g_reload_requested || g_stop_requested || g_sigchld_requested) {
      log_line("INFO", "epoll wake：eventType=control");
      handle_control_events(&scheduler);
    }

    if (!scheduler.running) break;

    if (saw_timer) {
      log_line("INFO", "epoll wake：eventType=timerfd, expirationCount=%llu",
               (unsigned long long)timer_expirations);
      run_due_tasks(&scheduler, timer_expirations);
    }

    (void)arm_timer_from_heap(&scheduler);
  }

  (void)disarm_timer(&scheduler);
  if (scheduler.epoll_fd >= 0) close(scheduler.epoll_fd);
  if (scheduler.event_fd >= 0) close(scheduler.event_fd);
  if (scheduler.timer_fd >= 0) close(scheduler.timer_fd);
  g_event_fd = -1;
  log_line("INFO", "native低开销定时器已退出");
  return 0;
}

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
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

#define MAX_JOBS 64
#define LINE_SIZE 512
#define SOURCE_SIZE 128
#define PATH_SIZE 512

typedef enum {
  JOB_DAILY = 1,
  JOB_INTERVAL = 2
} job_type_t;

typedef struct {
  job_type_t type;
  int hour;
  int minute;
  int interval_sec;
  time_t next_epoch;
  char source[SOURCE_SIZE];
} job_t;

static char g_moddir[PATH_SIZE];
static char g_schedule_file[PATH_SIZE];
static char g_log_file[PATH_SIZE];
static const char *g_clock_name = "CLOCK_BOOTTIME_ALARM";

static void trim_newline(char *s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ' || s[len - 1] == '\t')) {
    s[len - 1] = '\0';
    len--;
  }
}

static void log_line(const char *level, const char *fmt, ...) {
  FILE *fp = fopen(g_log_file, "a");
  if (!fp) return;

  time_t now = time(NULL);
  struct tm tm_now;
  localtime_r(&now, &tm_now);
  char time_buf[32];
  strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M:%S", &tm_now);

  fprintf(fp, "%s [%s] ", time_buf, level);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(fp, fmt, ap);
  va_end(ap);
  fprintf(fp, "\n");
  fclose(fp);
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

static int load_jobs(job_t *jobs, int max_jobs) {
  FILE *fp = fopen(g_schedule_file, "r");
  if (!fp) {
    log_line("ERROR", "无法读取定时表：%s，错误=%s", g_schedule_file, strerror(errno));
    return 0;
  }

  char line[LINE_SIZE];
  int count = 0;
  time_t now = time(NULL);

  while (fgets(line, sizeof(line), fp) && count < max_jobs) {
    trim_newline(line);
    if (line[0] == '\0' || line[0] == '#') continue;

    char *type = strtok(line, "|");
    char *value = strtok(NULL, "|");
    char *source = strtok(NULL, "|");
    if (!type || !value || !source) {
      log_line("WARN", "跳过无效定时行");
      continue;
    }

    job_t *job = &jobs[count];
    memset(job, 0, sizeof(*job));
    snprintf(job->source, sizeof(job->source), "%s", source);

    if (strcmp(type, "daily") == 0) {
      if (!parse_time_hhmm(value, &job->hour, &job->minute)) {
        log_line("WARN", "跳过无效每天定点时间：%s", value);
        continue;
      }
      job->type = JOB_DAILY;
      job->next_epoch = next_daily_epoch(now, job->hour, job->minute);
      count++;
    } else if (strcmp(type, "interval") == 0) {
      long minutes = strtol(value, NULL, 10);
      if (minutes < 1 || minutes > 1440) {
        log_line("WARN", "跳过无效固定间隔分钟数：%s", value);
        continue;
      }
      job->type = JOB_INTERVAL;
      job->interval_sec = (int)(minutes * 60);
      job->next_epoch = now + job->interval_sec;
      count++;
    } else {
      log_line("WARN", "跳过未知定时类型：%s", type);
    }
  }

  fclose(fp);
  return count;
}

static time_t earliest_due(job_t *jobs, int count) {
  time_t earliest = 0;
  for (int i = 0; i < count; i++) {
    if (earliest == 0 || jobs[i].next_epoch < earliest) earliest = jobs[i].next_epoch;
  }
  return earliest;
}

static int create_timerfd_with_fallback(void) {
  int fd = timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_CLOEXEC);
  if (fd >= 0) {
    g_clock_name = "CLOCK_BOOTTIME_ALARM";
    log_line("INFO", "native定时器使用唤醒闹钟时钟：%s", g_clock_name);
    return fd;
  }

  log_line("WARN", "CLOCK_BOOTTIME_ALARM不可用，息屏深睡时可能延迟：%s", strerror(errno));
  fd = timerfd_create(CLOCK_BOOTTIME, TFD_CLOEXEC);
  if (fd >= 0) {
    g_clock_name = "CLOCK_BOOTTIME";
    log_line("INFO", "native定时器降级使用：%s", g_clock_name);
    return fd;
  }

  log_line("WARN", "CLOCK_BOOTTIME不可用，继续降级：%s", strerror(errno));
  fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
  if (fd >= 0) {
    g_clock_name = "CLOCK_MONOTONIC";
    log_line("INFO", "native定时器降级使用：%s", g_clock_name);
    return fd;
  }

  log_line("ERROR", "timerfd创建失败：%s", strerror(errno));
  return -1;
}

static int arm_timer(int timer_fd, int seconds) {
  if (seconds < 1) seconds = 1;
  struct itimerspec spec;
  memset(&spec, 0, sizeof(spec));
  spec.it_value.tv_sec = seconds;
  return timerfd_settime(timer_fd, 0, &spec, NULL);
}

static void run_job(const job_t *job) {
  char cmd[PATH_SIZE + SOURCE_SIZE + 80];
  snprintf(cmd, sizeof(cmd), "sh '%s/script/run_task.sh' '%s' 0", g_moddir, job->source);
  log_line("INFO", "native定时触发：%s", job->source);
  int rc = system(cmd);
  if (rc == -1) {
    log_line("ERROR", "native定时执行失败：%s，错误=%s", job->source, strerror(errno));
  } else if (WIFEXITED(rc)) {
    log_line("INFO", "native定时执行结束：%s，退出码=%d", job->source, WEXITSTATUS(rc));
  } else {
    log_line("WARN", "native定时执行异常结束：%s，状态=%d", job->source, rc);
  }
}

int main(int argc, char **argv) {
  if (argc < 5) {
    return 2;
  }

  snprintf(g_moddir, sizeof(g_moddir), "%s", argv[1]);
  snprintf(g_schedule_file, sizeof(g_schedule_file), "%s", argv[3]);
  snprintf(g_log_file, sizeof(g_log_file), "%s", argv[4]);

  job_t jobs[MAX_JOBS];
  int job_count = load_jobs(jobs, MAX_JOBS);
  if (job_count <= 0) {
    log_line("WARN", "native定时器没有可用任务，退出");
    return 0;
  }

  int timer_fd = create_timerfd_with_fallback();
  if (timer_fd < 0) return 1;

  int epoll_fd = epoll_create1(EPOLL_CLOEXEC);
  if (epoll_fd < 0) {
    log_line("ERROR", "epoll创建失败：%s", strerror(errno));
    close(timer_fd);
    return 1;
  }

  struct epoll_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.events = EPOLLIN;
  ev.data.fd = timer_fd;
  if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, timer_fd, &ev) != 0) {
    log_line("ERROR", "epoll注册timerfd失败：%s", strerror(errno));
    close(epoll_fd);
    close(timer_fd);
    return 1;
  }

  log_line("INFO", "native低开销定时器已进入等待：任务数=%d，时钟=%s", job_count, g_clock_name);

  while (1) {
    time_t now = time(NULL);
    time_t due = earliest_due(jobs, job_count);
    int delay = (int)(due - now);
    if (arm_timer(timer_fd, delay) != 0) {
      log_line("ERROR", "设置timerfd失败：%s", strerror(errno));
      break;
    }

    struct epoll_event out;
    int n = epoll_wait(epoll_fd, &out, 1, -1);
    if (n < 0) {
      if (errno == EINTR) continue;
      log_line("ERROR", "epoll等待失败：%s", strerror(errno));
      break;
    }

    uint64_t expirations = 0;
    (void)read(timer_fd, &expirations, sizeof(expirations));

    now = time(NULL);
    for (int i = 0; i < job_count; i++) {
      if (jobs[i].next_epoch <= now) {
        run_job(&jobs[i]);
        now = time(NULL);
        if (jobs[i].type == JOB_DAILY) {
          jobs[i].next_epoch = next_daily_epoch(now, jobs[i].hour, jobs[i].minute);
        } else {
          jobs[i].next_epoch = now + jobs[i].interval_sec;
        }
      }
    }
  }

  close(epoll_fd);
  close(timer_fd);
  log_line("INFO", "native低开销定时器已退出");
  return 0;
}

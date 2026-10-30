import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';

const HOST: string = 'https://appassets.local';
const TAG: string = 'OpenGymTimer';

class RestNotifier {
  private ctx: common.UIAbilityContext | null = null;
  private tickId: number = -1;
  private remaining: number = 0;
  private label: string = '休息';
  private permRequested: boolean = false;
  private reminderId: number = -1;
  private reminderPending: boolean = false;
  private lastSyncSec: number = -1;

  attach(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
    hilog.info(0x0000, TAG, 'attach ok');
    // 只在启动时请求一次通知权限，避免反复弹窗刷坏状态
    this.requestPermission();
    // 清理本应用残留的提醒，避免数量超限
    try {
      reminderAgentManager.getValidReminders().then((list: reminderAgentManager.ReminderRequest[]) => {
        hilog.info(0x0000, TAG, 'valid reminders before cleanup = %{public}d', list.length);
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'getValidReminders fail: %{public}s', e.message ?? '');
      });
      reminderAgentManager.cancelAllReminders().then(() => {
        hilog.info(0x0000, TAG, 'cancelAllReminders ok');
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'cancelAllReminders fail: %{public}s', e.message ?? '');
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'cancelAllReminders err: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  private requestPermission(): void {
    if (this.permRequested) {
      return;
    }
    this.permRequested = true;
    try {
      const on: boolean = notificationManager.isNotificationEnabledSync();
      hilog.info(0x0000, TAG, 'notification enabled = %{public}s', on ? 'true' : 'false');
      if (on) {
        return;
      }
      if (this.ctx !== null) {
        notificationManager.requestEnableNotification(this.ctx).catch((e: Error) => {
          hilog.warn(0x0000, TAG, 'request permission fail: %{public}s', e.message ?? '');
        });
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'requestPermission err: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  fmt(sec: number): string {
    const m: number = Math.floor(sec / 60);
    const s: number = sec % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  private publishReminder(sec: number): void {
    if (this.reminderId >= 0 || this.reminderPending) {
      return;
    }
    this.reminderPending = true;
    try {
      const req: reminderAgentManager.ReminderRequestTimer = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
        triggerTimeInSeconds: sec,
        title: '休息结束',
        content: '该开始下一组了'
      };
      reminderAgentManager.publishReminder(req).then((id: number) => {
        this.reminderId = id;
        this.reminderPending = false;
        hilog.info(0x0000, TAG, 'reminder published id=%{public}d sec=%{public}d', id, sec);
      }).catch((e: Error) => {
        this.reminderPending = false;
        hilog.warn(0x0000, TAG, 'publishReminder fail: %{public}s', e.message ?? '');
      });
    } catch (e) {
      this.reminderPending = false;
      hilog.warn(0x0000, TAG, 'publishReminder err: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  private cancelReminder(): void {
    if (this.reminderId < 0) {
      this.reminderPending = false;
      return;
    }
    const id: number = this.reminderId;
    this.reminderId = -1;
    this.reminderPending = false;
    try {
      reminderAgentManager.cancelReminder(id).catch(() => {});
      hilog.info(0x0000, TAG, 'reminder cancelled id=%{public}d', id);
    } catch (e) {
      // 忽略
    }
  }

  publish(title: string, text: string): void {
    if (this.ctx === null) {
      hilog.warn(0x0000, TAG, 'publish skipped: no ctx');
      return;
    }
    try {
      const req: notificationManager.NotificationRequest = {
        id: 1001,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: text }
        }
      };
      notificationManager.publish(req).then(() => {
        hilog.info(0x0000, TAG, 'publish ok: %{public}s', text);
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'publish fail: %{public}s', e.message ?? '');
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'publish err: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  stopTick(): void {
    if (this.tickId >= 0) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
  }

  sync(sec: number, paused: boolean, label: string): void {
    this.label = label.length > 0 ? label : '休息';
    if (paused) {
      this.stopTick();
      this.cancelReminder();
      this.lastSyncSec = -1;
      this.remaining = sec;
      this.publish('休息已暂停', this.fmt(sec));
      return;
    }
    if (sec <= 0) {
      this.clear();
      return;
    }
    // 休息倒计时中：发布/更新「结束提醒」，退后台/锁屏到点也会响铃
    const jump: boolean = this.lastSyncSec >= 0 && Math.abs(sec - this.lastSyncSec) > 3;
    if (this.reminderId < 0) {
      this.publishReminder(sec);
    } else if (jump) {
      this.cancelReminder();
      this.publishReminder(sec);
    }
    this.lastSyncSec = sec;

    if (this.tickId < 0 || Math.abs(this.remaining - sec) > 2) {
      this.remaining = sec;
      this.stopTick();
      this.tickId = setInterval(() => {
        this.remaining -= 1;
        if (this.remaining <= 0) {
          this.clear();
        } else {
          this.publish(this.label, this.fmt(this.remaining));
        }
      }, 1000);
    }
    this.publish(this.label, this.fmt(sec));
  }

  clear(): void {
    this.stopTick();
    this.cancelReminder();
    this.lastSyncSec = -1;
    this.remaining = 0;
    try {
      notificationManager.cancel(1001).catch(() => {});
    } catch (e) {
      // 忽略取消失败
    }
  }
}

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  private ctx: common.UIAbilityContext | null = null;
  private notifier: RestNotifier = new RestNotifier();
  private proxyLoaded: boolean = false;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
  }

  aboutToDisappear(): void {
    this.notifier.clear();
    try {
      this.controller.deleteJavaScriptRegister('nativeTimer');
    } catch (e) {
      // 忽略
    }
  }

  mime(path: string): string {
    const p: string = path.toLowerCase();
    if (p.endsWith('.html')) return 'text/html';
    if (p.endsWith('.js') || p.endsWith('.mjs')) return 'text/javascript';
    if (p.endsWith('.css')) return 'text/css';
    if (p.endsWith('.json') || p.endsWith('.map')) return 'application/json';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.svg')) return 'image/svg+xml';
    if (p.endsWith('.mp4')) return 'video/mp4';
    if (p.endsWith('.woff2')) return 'font/woff2';
    if (p.endsWith('.woff')) return 'font/woff';
    if (p.endsWith('.txt')) return 'text/plain';
    return 'application/octet-stream';
  }

  isText(path: string): boolean {
    return /\.(html|js|mjs|css|json|map|svg|txt)$/i.test(path);
  }

  intercept(event: OnInterceptRequestEvent): WebResourceResponse | null {
    const url: string = event.request.getRequestUrl();
    if (!url.startsWith(HOST)) {
      return null;
    }
    let path: string = url.substring(HOST.length);
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    const hash: number = path.indexOf('#');
    if (hash >= 0) {
      path = path.substring(0, hash);
    }
    if (path === '' || path === '/') {
      path = '/index.html';
    }
    const rel: string = `www${path}`;
    const res: WebResourceResponse = new WebResourceResponse();
    if (this.ctx === null) {
      res.setResponseCode(500);
      res.setResponseData('context missing');
      res.setResponseMimeType('text/plain');
      return res;
    }
    try {
      const bytes: Uint8Array = this.ctx.resourceManager.getRawFileContentSync(rel);
      res.setResponseData(bytes.buffer as ArrayBuffer);
      res.setResponseMimeType(this.mime(path));
      if (this.isText(path)) {
        res.setResponseEncoding('utf-8');
      }
      res.setResponseCode(200);
      res.setReasonMessage('OK');
      return res;
    } catch (e) {
      res.setResponseData('not found');
      res.setResponseMimeType('text/plain');
      res.setResponseCode(404);
      res.setReasonMessage('Not Found');
      return res;
    }
  }

  onBackPress(): boolean {
    if (this.controller.accessBackward()) {
      this.controller.backward();
      return true;
    }
    return false;
  }

  inject(): void {
    const css: string = [
      '.conn-bar{background:transparent!important;-webkit-backdrop-filter:none!important;backdrop-filter:none!important;}',
      '.whdr.stick{border-radius:0 0 18px 18px;overflow:hidden;}',
      '.sect-b,.sect,.section{overflow:hidden!important;}',
      '.sect-b{border-radius:18px!important;}',
      ':focus,:focus-visible,*:focus,*:focus-visible{outline:none!important;box-shadow:none!important;border-color:transparent!important;}',
      '*{-webkit-tap-highlight-color:transparent;}',
      'html,body{scrollbar-width:none;-ms-overflow-style:none;}',
      '::-webkit-scrollbar{width:0!important;height:0!important;display:none!important;background:transparent!important;}',
      '*{scrollbar-width:none;}'
    ].join('');
    const js: string = `(()=>{let s=document.getElementById('harmony-fix');if(!s){s=document.createElement('style');s.id='harmony-fix';s.textContent=${JSON.stringify(css)};document.head.appendChild(s);}})();`;
    this.controller.runJavaScript(js);
    const poll: string = `(()=>{if(window.__harmonyTimerPoll)return;window.__harmonyTimerPoll=true;setInterval(()=>{try{const el=document.getElementById('timer');if(!el||!el.classList.contains('rest')){if(window.nativeTimer)window.nativeTimer.clear();return;}const paused=el.classList.contains('paused');const tEl=el.querySelector('.t');const t=(tEl&&tEl.textContent)||'';const p=t.split(':');let sec=0;if(p.length===2){const mm=parseInt(p[0],10);const ss=parseInt(p[1],10);if(!isNaN(mm)&&!isNaN(ss))sec=mm*60+ss;}const lblEl=el.querySelector('.lbl');const lbl=(lblEl&&lblEl.textContent)||'休息';if(window.nativeTimer)window.nativeTimer.sync(sec,paused,lbl);}catch(e){}},1000);})();`;
    this.controller.runJavaScript(poll);
    const vis: string = `(()=>{if(window.__harmonyVis)return;window.__harmonyVis=true;document.addEventListener('visibilitychange',()=>{const vids=document.querySelectorAll('video');if(document.hidden){vids.forEach(v=>{try{v.pause();}catch(e){}});}else{vids.forEach(v=>{try{if(v.classList.contains('catvid')&&v.paused)v.play();}catch(e){}});}});})();`;
    this.controller.runJavaScript(vis);
  }

  build() {
    Column() {
      Web({ src: `${HOST}/index.html`, controller: this.controller })
        .domStorageAccess(true)
        .databaseAccess(true)
        .fileAccess(true)
        .javaScriptAccess(true)
        .imageAccess(true)
        .mediaPlayGestureAccess(true)
        .zoomAccess(true)
        .enableWebAVSession(false)
        .onControllerAttached(() => {
          this.ctx = getContext(this) as common.UIAbilityContext;
          if (this.ctx !== null) {
            this.notifier.attach(this.ctx);
            try {
              this.controller.registerJavaScriptProxy(this.notifier, 'nativeTimer', ['sync', 'clear']);
            } catch (e) {
              hilog.warn(0x0000, TAG, 'register proxy fail: %{public}s', JSON.stringify(e) ?? '');
            }
          }
        })
        .onInterceptRequest((event: OnInterceptRequestEvent) => {
          return this.intercept(event);
        })
        .onPageEnd(() => {
          // 注册的 JS 对象要到下一次加载才生效：首次加载完成后重新加载一次，再注入
          if (!this.proxyLoaded) {
            this.proxyLoaded = true;
            this.controller.loadUrl(`${HOST}/index.html`);
          } else {
            this.inject();
          }
        })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}

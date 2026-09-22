package main

// Landing page at GET / — PiliSync's public face. Version, changelog and
// download links are read live from data/latest.json so the page never needs
// manual updates; GitHub Releases stays as the fallback channel.
// The app icon is embedded and served at /icon.png.

import (
	_ "embed"
	"encoding/json"
	"html"
	"net/http"
	"os"
	"strings"
)

//go:embed assets/icon.png
var siteIcon []byte

var siteReleasesFallback = "https://github.com/RayMorTwinkle/PiliSync/releases/latest"

func serveIcon(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write(siteIcon)
}

func serveIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	tag, body, apk, dmg := "", "", "", ""
	if raw, err := os.ReadFile(latestFilePath); err == nil {
		var lf latestFile
		if json.Unmarshal(raw, &lf) == nil {
			tag = lf.TagName
			body = lf.Body
			for _, a := range lf.Assets {
				switch {
				case strings.HasSuffix(a.Name, ".apk"):
					apk = a.BrowserDownloadURL
				case strings.HasSuffix(a.Name, ".dmg"):
					dmg = a.BrowserDownloadURL
				}
			}
		}
	}
	if apk == "" {
		apk = siteReleasesFallback
	}
	if dmg == "" {
		dmg = siteReleasesFallback
	}
	verBadge := "获取最新版"
	if tag != "" {
		verBadge = tag
	}

	var b strings.Builder
	b.WriteString(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PiliSync — 和朋友一起看 B 站</title>
<meta name="description" content="PiliSync：B 站第三方客户端 PiliPlus 的增强 fork，新增「一起看」——同步进度观影、双人语音通话、房主转让、国内渠道更新。">
<link rel="icon" type="image/png" href="/icon.png">
<style>
:root{--pink:#fb7299;--green:#43a85f;--ink:#1d1d1f;--sub:#6e6e73;--line:#e8e8ed;
  --bg:#fbfbfd;--card:#fff;--card2:#f5f5f7;color-scheme:light}
*{box-sizing:border-box;margin:0}
html{scroll-behavior:smooth}
body{font-family:-apple-system,"SF Pro SC","PingFang SC","HarmonyOS Sans SC","Microsoft YaHei",system-ui,sans-serif;
  color:var(--ink);background:var(--bg);line-height:1.65;-webkit-font-smoothing:antialiased;overflow-x:hidden}
.wrap{max-width:880px;margin:0 auto;padding:0 24px}
a{text-decoration:none;color:inherit}

/* ── nav ── */
nav{position:sticky;top:0;z-index:10;backdrop-filter:saturate(180%) blur(16px);
  background:rgba(251,251,253,.75);border-bottom:1px solid var(--line)}
nav .wrap{display:flex;align-items:center;gap:10px;height:56px}
nav img{width:28px;height:28px;border-radius:7px}
nav .name{font-weight:700;font-size:1.05rem;letter-spacing:-.01em}
nav .sp{flex:1}
nav a.navlink{color:var(--sub);font-size:.88rem;padding:6px 4px}
nav a.navlink:hover{color:var(--pink)}

/* ── hero ── */
.hero{position:relative;text-align:center;padding:88px 0 72px}
.orb{position:absolute;border-radius:50%;filter:blur(80px);opacity:.5;pointer-events:none}
.orb1{width:340px;height:340px;background:#ffd6e3;top:-80px;left:-60px}
.orb2{width:300px;height:300px;background:#cdeed6;top:40px;right:-40px}
.orb3{width:220px;height:220px;background:#ffe9c7;bottom:-60px;left:38%}
.hero img.icon{width:96px;height:96px;border-radius:24px;position:relative;
  box-shadow:0 12px 32px rgba(67,168,95,.35);animation:rise .7s ease both}
h1{font-size:3rem;font-weight:800;letter-spacing:-.03em;position:relative;
  animation:rise .7s .08s ease both}
.tag{font-size:1.2rem;color:var(--sub);margin-top:14px;position:relative;
  animation:rise .7s .16s ease both}
.ver{display:inline-flex;align-items:center;gap:6px;margin-top:18px;padding:5px 14px;
  border-radius:980px;background:#eef7f0;color:var(--green);font-size:.82rem;font-weight:600;
  position:relative;animation:rise .7s .22s ease both}
.dl{display:flex;gap:14px;justify-content:center;margin-top:34px;flex-wrap:wrap;position:relative;
  animation:rise .7s .3s ease both}
.btn{display:inline-flex;align-items:center;gap:8px;padding:14px 30px;border-radius:980px;
  font-size:1rem;font-weight:600;transition:transform .15s,box-shadow .15s}
.btn:active{transform:scale(.96)}
.btn-p{background:linear-gradient(135deg,#fb7299,#f25d8e);color:#fff;
  box-shadow:0 6px 20px rgba(242,93,142,.4)}
.btn-p:hover{box-shadow:0 10px 28px rgba(242,93,142,.5);transform:translateY(-1px)}
.btn-s{background:var(--card);color:var(--ink);border:1px solid var(--line)}
.btn-s:hover{border-color:#b8b8bd;transform:translateY(-1px)}
.gh{display:block;margin-top:20px;color:var(--sub);font-size:.85rem;position:relative;
  animation:rise .7s .36s ease both}
.gh:hover{color:var(--pink)}
@keyframes rise{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}

/* ── sections ── */
section{padding:56px 0}
.sec-t{text-align:center;font-size:1.6rem;font-weight:700;letter-spacing:-.01em;margin-bottom:8px}
.sec-s{text-align:center;color:var(--sub);font-size:.95rem;margin-bottom:36px}

.steps{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}
.step{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:26px;position:relative}
.step .n{width:34px;height:34px;border-radius:50%;background:linear-gradient(135deg,var(--pink),#f25d8e);
  color:#fff;font-weight:700;display:flex;align-items:center;justify-content:center;font-size:.95rem;margin-bottom:14px}
.step h3{font-size:1.02rem;margin-bottom:6px}
.step p{color:var(--sub);font-size:.88rem}

.feats{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}
.feat{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:24px;
  transition:transform .2s,box-shadow .2s}
.feat:hover{transform:translateY(-3px);box-shadow:0 12px 30px rgba(0,0,0,.07)}
.feat .ic{width:44px;height:44px;border-radius:12px;display:flex;align-items:center;justify-content:center;
  font-size:1.3rem;margin-bottom:14px;background:var(--card2)}
.feat h3{font-size:1rem;margin-bottom:5px}
.feat p{color:var(--sub);font-size:.86rem}

.log{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:28px;max-width:640px;margin:0 auto}
.log .tag{font-size:.8rem;color:var(--green);font-weight:600;margin:0 0 10px;text-align:left;animation:none}
.log .changes{color:var(--sub);font-size:.9rem;white-space:pre-wrap;max-height:12em;overflow:hidden;position:relative}

footer{border-top:1px solid var(--line);padding:32px 0 44px;color:var(--sub);font-size:.82rem;text-align:center}
footer a{color:var(--pink)}
footer .links{margin-bottom:10px}
footer .links a{margin:0 10px;color:var(--sub)}
footer .links a:hover{color:var(--pink)}

@media (prefers-color-scheme:dark){
:root{--ink:#f5f5f7;--sub:#a1a1a6;--line:#2d2d2f;--bg:#000;--card:#161617;--card2:#212122;color-scheme:dark}
nav{background:rgba(0,0,0,.7)}
.orb{opacity:.28}
.btn-s{background:#161617}
.ver{background:#12271a}
.log .tag{color:#6fd08c}
}
@media (max-width:560px){h1{font-size:2.2rem}.hero{padding:64px 0 52px}}
</style></head><body>

<nav><div class="wrap">
<img src="/icon.png" alt="PiliSync"><span class="name">PiliSync</span><span class="sp"></span>
<a class="navlink" href="#how">怎么用</a>
<a class="navlink" href="#features">特性</a>
<a class="navlink" href="https://github.com/RayMorTwinkle/PiliSync" rel="noopener">GitHub</a>
</div></nav>

<div class="hero"><div class="orb orb1"></div><div class="orb orb2"></div><div class="orb orb3"></div>
<img class="icon" src="/icon.png" alt="PiliSync">
<h1>PiliSync</h1>
<p class="tag">B 站第三方客户端，和朋友「一起看」<br>同步进度观影 · 双人语音通话 · 跨 Android / macOS</p>
<span class="ver">◆ ` + html.EscapeString(verBadge) + `</span>
<div class="dl">
<a class="btn btn-p" href="` + html.EscapeString(apk) + `">⬇ 下载 Android</a>
<a class="btn btn-s" href="` + html.EscapeString(dmg) + `">⬇ 下载 macOS</a>
</div>
<a class="gh" href="https://github.com/RayMorTwinkle/PiliSync/releases" rel="noopener">GitHub Releases · 历史版本 →</a>
</div>

<div class="wrap">
<section id="how">
<div class="sec-t">三步开看</div>
<div class="sec-s">不用注册，不用加好友——一个房号就够了</div>
<div class="steps">
<div class="step"><div class="n">1</div><h3>创建房间</h3><p>「我的」页右上角进入一起看，一键建房，拿到 6 位房号发给朋友。</p></div>
<div class="step"><div class="n">2</div><h3>好友进房</h3><p>对方输入房号即加入，自动跟随你正在看的视频——不用手动点播放。</p></div>
<div class="step"><div class="n">3</div><h3>同步 + 语音</h3><p>播放、暂停、进度、倍速实时对齐，一键开语音边看边聊。</p></div>
</div>
</section>

<section id="features">
<div class="sec-t">为一起看而生</div>
<div class="sec-s">不是简单的进度对齐，是一套完整的房间协议</div>
<div class="feats">
<div class="feat"><div class="ic">🎬</div><h3>毫秒级同步</h3><p>NTP 对时 + 外推校准，seek、倍速、换视频全员瞬间跟随。</p></div>
<div class="feat"><div class="ic">🎙️</div><h3>双人语音</h3><p>WebRTC 直连通话，可调语音阈值降噪、远端音量、静音控制。</p></div>
<div class="feat"><div class="ic">👑</div><h3>房主优先</h3><p>房主转让、绝对优先模式——成员卡顿、暂停都不会拖累房主。</p></div>
<div class="feat"><div class="ic">🍃</div><h3>宽松同步</h3><p>加载慢的成员自动追赶而不是互相等待，网络差也能一起看。</p></div>
<div class="feat"><div class="ic">🔌</div><h3>断线自愈</h3><p>杀进程、切后台、网络抖动后自动重连并回到房间当前进度。</p></div>
<div class="feat"><div class="ic">🚀</div><h3>国内渠道更新</h3><p>内置更新检查走国内分发渠道，GitHub 打不开也能升级。</p></div>
</div>
</section>
`)

	if body != "" {
		b.WriteString(`<section><div class="sec-t">更新日志</div><div class="sec-s">` + html.EscapeString(tag) + `</div>
<div class="log"><div class="changes">` + html.EscapeString(body) + `</div></div></section>`)
	}

	b.WriteString(`</div>
<footer><div class="wrap">
<div class="links"><a href="https://github.com/RayMorTwinkle/PiliSync" rel="noopener">GitHub</a><a href="https://github.com/bggRGjQaUbCoE/PiliPlus" rel="noopener">PiliPlus 上游</a></div>
PiliSync 由 RayMor 基于 PiliPlus fork 并增强 · 仅供学习交流
</div></footer>
</body></html>`)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write([]byte(b.String()))
}

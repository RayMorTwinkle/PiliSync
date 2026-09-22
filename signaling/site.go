package main

// Landing page at GET / — PiliSync's public face. Version and download links
// are read live from data/latest.json so the page never needs manual updates;
// GitHub Releases stays as the fallback channel.

import (
	"encoding/json"
	"html"
	"net/http"
	"os"
	"strings"
)

var siteReleasesFallback = "https://github.com/RayMorTwinkle/PiliSync/releases/latest"

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
	// No domestic build published yet → buttons still work, pointing at GitHub.
	if apk == "" {
		apk = siteReleasesFallback
	}
	if dmg == "" {
		dmg = siteReleasesFallback
	}
	if tag == "" {
		tag = "最新版"
	}
	var b strings.Builder
	b.WriteString(`<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PiliSync — 一起看</title>
<meta name="description" content="PiliSync：B 站第三方客户端 PiliPlus 的增强 fork，新增「一起看」——和好友同步进度看视频，支持实时语音通话。">
<style>
:root{color-scheme:light}
*{box-sizing:border-box;margin:0}
body{font-family:-apple-system,"SF Pro SC","PingFang SC","HarmonyOS Sans SC","Microsoft YaHei",system-ui,sans-serif;
  color:#1d1d1f;background:#fbfbfd;line-height:1.6;-webkit-font-smoothing:antialiased}
.wrap{max-width:760px;margin:0 auto;padding:0 24px}
.hero{padding:96px 0 56px;text-align:center}
.logo{width:72px;height:72px;border-radius:18px;margin:0 auto 24px;display:block;
  background:linear-gradient(135deg,#fb7299,#f25d8e);color:#fff;
  font-size:34px;font-weight:700;line-height:72px;text-align:center;
  box-shadow:0 8px 24px rgba(242,93,142,.35)}
h1{font-size:2.4rem;font-weight:700;letter-spacing:-.02em}
.tag{color:#86868b;font-size:1.15rem;margin-top:10px}
.ver{color:#fb7299;font-weight:600}
.dl{display:flex;gap:14px;justify-content:center;margin-top:36px;flex-wrap:wrap}
.btn{display:inline-flex;align-items:center;gap:8px;padding:13px 28px;border-radius:980px;
  font-size:1rem;font-weight:600;text-decoration:none;transition:transform .15s,box-shadow .15s}
.btn:active{transform:scale(.97)}
.btn-p{background:#1d1d1f;color:#fff;box-shadow:0 4px 14px rgba(0,0,0,.18)}
.btn-p:hover{box-shadow:0 6px 20px rgba(0,0,0,.26)}
.btn-s{background:#fff;color:#1d1d1f;border:1px solid #d2d2d7}
.btn-s:hover{border-color:#86868b}
.gh{display:block;margin-top:18px;color:#86868b;font-size:.85rem;text-decoration:none}
.gh:hover{color:#fb7299}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px;padding:24px 0 40px}
.card{background:#fff;border:1px solid #e8e8ed;border-radius:16px;padding:24px}
.card h3{font-size:1.05rem;margin-bottom:6px}
.card p{color:#6e6e73;font-size:.9rem}
.card .ic{font-size:1.4rem;display:block;margin-bottom:10px}
.note{background:#fff;border-top:1px solid #e8e8ed;padding:32px 0 48px;color:#86868b;font-size:.85rem}
.note a{color:#fb7299;text-decoration:none}
.changes{color:#6e6e73;margin-top:8px;white-space:pre-wrap;display:block;max-height:7.5em;overflow:hidden}
@media (prefers-color-scheme:dark){
:root{color-scheme:dark}
body{background:#000;color:#f5f5f7}
.card{background:#161617;border-color:#2d2d2f}
.card p{color:#a1a1a6}
.btn-s{background:#161617;color:#f5f5f7;border-color:#424245}
.btn-p{background:#f5f5f7;color:#1d1d1f}
.note{background:#000;border-color:#2d2d2f}
}
</style>
<div class="wrap"><section class="hero">
<div class="logo">同</div>
<h1>PiliSync</h1>
<p class="tag">B 站第三方客户端 · <span class="ver">` + html.EscapeString(tag) + `</span><br>和好友同步进度看视频，还能语音通话</p>
<div class="dl">
<a class="btn btn-p" href="` + html.EscapeString(apk) + `">⬇ 下载 Android</a>
<a class="btn btn-s" href="` + html.EscapeString(dmg) + `">⬇ 下载 macOS</a>
</div>
<a class="gh" href="https://github.com/RayMorTwinkle/PiliSync" rel="noopener">GitHub 仓库 · Releases →</a>
</section>
<section class="cards">
<div class="card"><span class="ic">🎬</span><h3>一起看</h3><p>发房号邀请好友，进房自动跟随你正在看的视频，播放、暂停、进度、倍速实时同步。</p></div>
<div class="card"><span class="ic">🎙️</span><h3>语音通话</h3><p>房间内一键开启双人实时语音，带语音阈值降噪和远端音量调节，边看边聊。</p></div>
<div class="card"><span class="ic">👑</span><h3>房主优先</h3><p>房主转让、房主绝对优先、宽松同步——卡顿的成员不会拖住流畅的大家。</p></div>
<div class="card"><span class="ic">🚀</span><h3>国内渠道更新</h3><p>内置更新检查，国内渠道秒开下载页，GitHub 网络不佳也能第一时间升级。</p></div>
</section></div>
<div class="note"><div class="wrap">
PiliSync 由 RayMor 基于 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus" rel="noopener">PiliPlus</a> fork 并增强，仅供学习交流。`)
	if body != "" {
		b.WriteString(`<span class="changes">` + html.EscapeString(body) + `</span>`)
	}
	b.WriteString(`</div></div>`)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write([]byte(b.String()))
}

(() => {
  const bench = document.getElementById("bench");
  const slider = document.getElementById("offset");
  const offsetLabel = document.getElementById("offset-value");
  const roomTime = document.getElementById("target-time");
  const memberTime = document.getElementById("member-time");
  const pin = document.getElementById("member-pin");
  const decision = document.getElementById("decision");
  const details = document.getElementById("explain");
  const apply = document.getElementById("apply");
  const outcome = document.getElementById("outcome");

  // Integer tenths keep exact-threshold cases stable in the browser.
  const examples = {
    hold: { target: 420, offset: 26 },
    playing: { target: 440, offset: -16 },
    paused: { target: 420, offset: 6 },
    buffering: { target: 440, offset: -22 }
  };

  let mode = "hold";

  function clock(tenths) {
    const seconds = Math.floor(tenths / 10);
    return String(Math.floor(seconds / 60)).padStart(2, "0") + ":" +
      String(seconds % 60).padStart(2, "0") + "." + tenths % 10;
  }

  function relative(offset) {
    if (offset === 0) return "同一位置";
    return (offset > 0 ? "领先 " : "落后 ") + (Math.abs(offset) / 10).toFixed(1) + " 秒";
  }

  function chooseAction(offset) {
    const delta = Math.abs(offset);
    if (mode === "buffering") {
      return { label: "让成员继续缓冲", explain: "这位成员刚开始加载。此时跳转会丢弃正在填充的缓冲区，本轮保留当前进度。", seek: false };
    }
    if (mode === "hold") {
      const intro = "成员原先因领先而等待。房主现在暂停，先退出原有等待。";
      return delta > 1
        ? { label: "对准暂停点", explain: intro + " 两个暂停点相差超过 0.1 秒，跳到房主的位置。", seek: true }
        : { label: "保持暂停", explain: intro + " 偏差在 0.1 秒以内，保留当前位置。", seek: false };
    }
    if (mode === "paused") {
      return delta > 1
        ? { label: "跳转并暂停", explain: "偏差超过 0.1 秒，成员对准房主停下的位置并暂停。", seek: true }
        : { label: "原地暂停", explain: "偏差在 0.1 秒以内，成员只需暂停。", seek: false };
    }
    return delta > 10
      ? { label: "跳转对齐", explain: "成员" + relative(offset) + "，超过播放态的 1 秒容差。", seek: true }
      : { label: "继续播放", explain: "偏差在 1 秒以内，成员沿当前进度继续播放。", seek: false };
  }

  function moveMember(target, offset) {
    memberTime.textContent = clock(target + offset);
    // The rail reserves a small margin for markers at either endpoint.
    pin.style.left = (50 + offset * 1.4) + "%";
  }

  function preview() {
    const offset = Number(slider.value);
    const target = examples[mode].target;
    const action = chooseAction(offset);
    offsetLabel.textContent = relative(offset);
    slider.setAttribute("aria-valuetext", relative(offset));
    roomTime.textContent = clock(target);
    moveMember(target, offset);
    decision.textContent = action.label;
    details.textContent = action.explain;
    outcome.textContent = "";
    apply.disabled = false;
  }

  bench.addEventListener("change", event => {
    if (event.target.name !== "mode") return;
    mode = event.target.value;
    slider.value = examples[mode].offset;
    preview();
  });
  slider.addEventListener("input", preview);
  apply.addEventListener("click", () => {
    const offset = Number(slider.value);
    const action = chooseAction(offset);
    const target = examples[mode].target;
    const resultingOffset = action.seek ? 0 : offset;
    moveMember(target, resultingOffset);
    outcome.textContent = "已执行「" + action.label + "」，成员位置 " + clock(target + resultingOffset) + "。";
    apply.disabled = true;
  });
  bench.querySelector("fieldset").disabled = false;
  slider.disabled = false;
  // Some browsers restore form state after a navigation.
  mode = bench.querySelector("input[name=mode]:checked").value;
  preview();
})();

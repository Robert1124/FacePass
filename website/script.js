(function () {
  const STORAGE_KEY = "facepass-site-language";
  const supported = new Set(["en", "zh"]);
  const body = document.body;
  const page = body.dataset.page || "home";
  const languageButtons = Array.from(document.querySelectorAll("[data-lang-set]"));
  let copyButtons = [];
  let translatable = [];
  const titles = {
    home: {
      en: "FacePass - Local macOS Unlock Assist",
      zh: "FacePass - 本地 macOS 解锁辅助"
    },
    docs: {
      en: "FacePass Documentation",
      zh: "FacePass 文档"
    },
    privacy: {
      en: "FacePass Privacy Policy",
      zh: "FacePass 隐私政策"
    },
    roadmap: {
      en: "FacePass Roadmap",
      zh: "FacePass 路线图"
    }
  };

  function preferredLanguage() {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (supported.has(saved)) {
      return saved;
    }
    return navigator.language && navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en";
  }

  function applyLanguage(language) {
    const next = supported.has(language) ? language : "en";
    document.documentElement.lang = next === "zh" ? "zh-Hans" : "en";
    document.title = titles[page] ? titles[page][next] : titles.home[next];
    translatable = Array.from(document.querySelectorAll("[data-en][data-zh]"));
    translatable.forEach((node) => {
      node.textContent = node.dataset[next];
    });
    copyButtons.forEach((button) => {
      const accessibleLabel = button.dataset.copyState === "copied" ? button.dataset[`${next}CopiedLabel`] : button.dataset[`${next}Label`];
      button.dataset.stateLabel = button.dataset.copyState === "copied" ? button.dataset[`${next}CopiedText`] : button.dataset[`${next}Text`];
      button.setAttribute("aria-label", accessibleLabel);
    });
    languageButtons.forEach((button) => {
      const active = button.dataset.langSet === next;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
    localStorage.setItem(STORAGE_KEY, next);
  }

  function currentLanguage() {
    return supported.has(localStorage.getItem(STORAGE_KEY)) ? localStorage.getItem(STORAGE_KEY) : preferredLanguage();
  }

  function updateCopyButton(button, state) {
    const language = currentLanguage();
    button.dataset.copyState = state;
    const stateKey = state === "copied" ? "Copied" : "";
    button.dataset.stateLabel = state === "copied" ? button.dataset[`${language}${stateKey}Text`] : button.dataset[`${language}Text`];
    button.setAttribute(
      "aria-label",
      state === "copied" ? button.dataset[`${language}CopiedLabel`] : button.dataset[`${language}Label`]
    );
  }

  async function copyCodeText(button, code) {
    const text = (code.dataset.rawCode || code.textContent).replace(/\s+$/, "");
    try {
      await navigator.clipboard.writeText(text);
      updateCopyButton(button, "copied");
      window.clearTimeout(button.copyResetTimer);
      button.copyResetTimer = window.setTimeout(() => updateCopyButton(button, "idle"), 1600);
    } catch (error) {
      const range = document.createRange();
      const selection = window.getSelection();
      range.selectNodeContents(code);
      selection.removeAllRanges();
      selection.addRange(range);
      updateCopyButton(button, "copied");
      window.setTimeout(() => selection.removeAllRanges(), 1600);
    }
  }

  function setupCopyBlocks() {
    copyButtons = Array.from(document.querySelectorAll("pre")).map((pre, index) => {
      const code = pre.querySelector("code");
      const wrapper = document.createElement("div");
      const codeElement = code || pre;
      const rawCode = codeElement.textContent.replace(/\s+$/, "");
      const lines = rawCode.split("\n");
      const gutter = document.createElement("div");
      const button = document.createElement("button");
      wrapper.className = "code-block";
      gutter.className = "code-gutter";
      gutter.setAttribute("aria-hidden", "true");
      gutter.innerHTML = lines.map((_, lineIndex) => `<span>${lineIndex + 1}</span>`).join("");
      codeElement.dataset.rawCode = rawCode;
      codeElement.innerHTML = lines.map((line) => `<span class="code-line">${highlightShellLine(line) || "&nbsp;"}</span>`).join("");
      button.type = "button";
      button.className = "copy-button";
      button.dataset.enText = "Copy";
      button.dataset.zhText = "复制";
      button.dataset.enCopiedText = "Copied";
      button.dataset.zhCopiedText = "已复制";
      button.dataset.enLabel = `Copy code block ${index + 1}`;
      button.dataset.zhLabel = `复制第 ${index + 1} 个代码块`;
      button.dataset.enCopiedLabel = `Code block ${index + 1} copied`;
      button.dataset.zhCopiedLabel = `第 ${index + 1} 个代码块已复制`;
      button.dataset.copyState = "idle";
      button.innerHTML = '<span aria-hidden="true" class="copy-icon"></span>';
      pre.parentNode.insertBefore(wrapper, pre);
      wrapper.appendChild(gutter);
      wrapper.appendChild(pre);
      wrapper.appendChild(button);
      button.addEventListener("click", () => copyCodeText(button, codeElement));
      return button;
    });
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"']/g, (character) => {
      const entities = {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;"
      };
      return entities[character];
    });
  }

  function highlightShellLine(line) {
    return escapeHtml(line)
      .replace(/^(\s*)(git|cd|xcode-select|swift)(?=\s|$)/, '$1<span class="code-token command">$2</span>')
      .replace(/(^|\s)(--?[\w-]+)/g, '$1<span class="code-token option">$2</span>')
      .replace(/(https?:\/\/[^\s<]+)/g, '<span class="code-token url">$1</span>');
  }

  function setActiveNavigation() {
    document.querySelectorAll("[data-nav]").forEach((link) => {
      if (link.dataset.nav === page) {
        link.classList.add("is-active");
        link.setAttribute("aria-current", "page");
      }
    });
  }

  function setupReveal() {
    const revealNodes = Array.from(document.querySelectorAll("[data-reveal]"));
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) {
      revealNodes.forEach((node) => node.classList.add("is-visible"));
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.16, rootMargin: "0px 0px -40px" }
    );

    revealNodes.forEach((node) => {
      const rect = node.getBoundingClientRect();
      if (rect.top < window.innerHeight && rect.bottom > 0) {
        node.classList.add("is-visible");
        return;
      }
      observer.observe(node);
    });
  }

  setupCopyBlocks();
  setActiveNavigation();
  applyLanguage(preferredLanguage());
  setupReveal();

  languageButtons.forEach((button) => {
    button.addEventListener("click", () => {
      applyLanguage(button.dataset.langSet);
    });
  });
})();

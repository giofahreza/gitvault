(() => {
  const themeStorageKey = "gitvault.landing.theme";
  const darkThemeColor = "#180d0e";
  const lightThemeColor = "#f7efea";
  const root = document.documentElement;
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");

  function savedTheme() {
    try {
      const theme = window.localStorage.getItem(themeStorageKey);
      return theme === "light" || theme === "dark" ? theme : null;
    } catch {
      return null;
    }
  }

  function systemPreferredTheme() {
    return systemTheme.matches ? "dark" : "light";
  }

  function applyTheme(theme, toggle = document.querySelector("[data-theme-toggle]")) {
    const nextTheme = theme === "dark" ? "dark" : "light";
    root.dataset.theme = nextTheme;
    document.querySelector('meta[name="theme-color"]')?.setAttribute(
      "content",
      nextTheme === "dark" ? darkThemeColor : lightThemeColor,
    );

    if (!toggle) return;
    const nextThemeLabel = nextTheme === "dark" ? "light" : "dark";
    toggle.setAttribute("aria-label", `Switch to ${nextThemeLabel} theme`);
    toggle.setAttribute("aria-pressed", String(nextTheme === "dark"));
    toggle.title = `Switch to ${nextThemeLabel} theme`;
  }

  // This file is intentionally loaded in the document head so a saved theme is
  // applied before the stylesheet paints the page.
  applyTheme(savedTheme() ?? systemPreferredTheme(), null);

  function initializeLanding() {
    const themeToggle = document.querySelector("[data-theme-toggle]");
    applyTheme(root.dataset.theme ?? systemPreferredTheme(), themeToggle);

    themeToggle?.addEventListener("click", () => {
      const nextTheme = root.dataset.theme === "dark" ? "light" : "dark";
      try {
        window.localStorage.setItem(themeStorageKey, nextTheme);
      } catch {
        // The current visit still uses the selected theme when storage is unavailable.
      }
      applyTheme(nextTheme, themeToggle);
    });

    function followSystemTheme(event) {
      if (!savedTheme()) applyTheme(event.matches ? "dark" : "light", themeToggle);
    }

    if (systemTheme.addEventListener) {
      systemTheme.addEventListener("change", followSystemTheme);
    } else {
      systemTheme.addListener(followSystemTheme);
    }

    const header = document.querySelector(".site-header");
    const updateHeaderState = () => {
      header?.classList.toggle("is-scrolled", window.scrollY > 18);
    };
    updateHeaderState();
    window.addEventListener("scroll", updateHeaderState, { passive: true });

    const mobileMenu = document.querySelector(".mobile-menu");

    for (const link of document.querySelectorAll(".mobile-menu a")) {
      link.addEventListener("click", () => mobileMenu?.removeAttribute("open"));
    }

    document.addEventListener("click", (event) => {
      if (mobileMenu?.open && !mobileMenu.contains(event.target)) {
        mobileMenu.removeAttribute("open");
      }
    });

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && mobileMenu?.open) {
        mobileMenu.removeAttribute("open");
        mobileMenu.querySelector("summary")?.focus();
      }
    });

    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const revealItems = [...document.querySelectorAll(".reveal")];

    if (!reducedMotion && revealItems.length > 0 && "IntersectionObserver" in window) {
      root.classList.add("has-motion");

      const observer = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (!entry.isIntersecting) continue;
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        },
        { rootMargin: "0px 0px -6%", threshold: 0.08 },
      );

      for (const item of revealItems) observer.observe(item);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initializeLanding, { once: true });
  } else {
    initializeLanding();
  }
})();

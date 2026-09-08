const supportsReducedMotion = window.matchMedia(
  "(prefers-reduced-motion: reduce)",
).matches;

const items = [...document.querySelectorAll(".reveal")];

if (!supportsReducedMotion && items.length > 0 && "IntersectionObserver" in window) {
  document.documentElement.classList.add("has-motion");

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    },
    { threshold: 0.12 },
  );

  for (const item of items) observer.observe(item);
}

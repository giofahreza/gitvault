const canvas = document.querySelector("#vault-globe");

const prefersReducedMotion = window.matchMedia(
  "(prefers-reduced-motion: reduce)",
).matches;

if (canvas) {
  startScene(canvas).catch(() => startFallback(canvas));
}

initScreenshotSlider();

async function startScene(target) {
  const THREE = await import(
    "https://cdn.jsdelivr.net/npm/three@0.166.1/build/three.module.js"
  );

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 100);
  camera.position.set(0, 0, 7.6);

  const renderer = new THREE.WebGLRenderer({
    canvas: target,
    antialias: true,
    alpha: true,
  });
  renderer.setClearColor(0x000000, 0);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));

  const pointer = { x: 0, y: 0 };
  const group = new THREE.Group();
  scene.add(group);

  const count = 2300;
  const positions = new Float32Array(count * 3);
  const colors = new Float32Array(count * 3);

  for (let i = 0; i < count; i += 1) {
    const phi = Math.acos(2 * Math.random() - 1);
    const theta = Math.random() * Math.PI * 2;
    const radius = 2.35 + Math.random() * 0.28;
    const index = i * 3;

    positions[index] = radius * Math.sin(phi) * Math.cos(theta);
    positions[index + 1] = radius * Math.cos(phi);
    positions[index + 2] = radius * Math.sin(phi) * Math.sin(theta);

    const palette = Math.random();
    if (palette > 0.78) {
      colors[index] = 1;
      colors[index + 1] = 0.43;
      colors[index + 2] = 0.82;
    } else if (palette > 0.48) {
      colors[index] = 0.57;
      colors[index + 1] = 0.56;
      colors[index + 2] = 1;
    } else {
      colors[index] = 0.82;
      colors[index + 1] = 0.9;
      colors[index + 2] = 1;
    }
  }

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute("color", new THREE.BufferAttribute(colors, 3));

  const material = new THREE.PointsMaterial({
    size: 0.017,
    vertexColors: true,
    transparent: true,
    opacity: 0.82,
  });

  const points = new THREE.Points(geometry, material);
  group.add(points);

  const meshMaterial = new THREE.MeshBasicMaterial({
    color: 0xb8c5ff,
    wireframe: true,
    transparent: true,
    opacity: 0.11,
  });

  const mesh = new THREE.Mesh(new THREE.IcosahedronGeometry(2.68, 4), meshMaterial);
  const shell = new THREE.Mesh(
    new THREE.IcosahedronGeometry(2.78, 2),
    new THREE.MeshBasicMaterial({
      color: 0xffffff,
      wireframe: true,
      transparent: true,
      opacity: 0.055,
    }),
  );
  shell.rotation.z = Math.PI / 9;
  group.add(mesh, shell);

  const starGeometry = new THREE.BufferGeometry();
  const starCount = 520;
  const starPositions = new Float32Array(starCount * 3);
  for (let i = 0; i < starCount; i += 1) {
    const index = i * 3;
    starPositions[index] = (Math.random() - 0.5) * 14;
    starPositions[index + 1] = (Math.random() - 0.5) * 8;
    starPositions[index + 2] = -2 - Math.random() * 6;
  }
  starGeometry.setAttribute("position", new THREE.BufferAttribute(starPositions, 3));
  const stars = new THREE.Points(
    starGeometry,
    new THREE.PointsMaterial({
      color: 0xdde6ff,
      size: 0.01,
      transparent: true,
      opacity: 0.26,
    }),
  );
  scene.add(stars);

  function resize() {
    const rect = target.getBoundingClientRect();
    const width = Math.max(1, Math.round(rect.width));
    const height = Math.max(1, Math.round(rect.height));
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
    group.position.x = 0;
    group.position.y = width < 760 ? 0.18 : 0.02;
    group.scale.setScalar(width < 760 ? 0.68 : 0.72);
  }

  window.addEventListener("resize", resize, { passive: true });
  window.addEventListener(
    "pointermove",
    (event) => {
      pointer.x = (event.clientX / window.innerWidth - 0.5) * 0.5;
      pointer.y = (event.clientY / window.innerHeight - 0.5) * 0.5;
    },
    { passive: true },
  );
  resize();

  function render(time = 0) {
    const speed = prefersReducedMotion ? 0.00004 : 0.00016;
    group.rotation.y = time * speed + pointer.x;
    group.rotation.x = -0.08 + pointer.y;
    stars.rotation.y = time * 0.000035;
    renderer.render(scene, camera);
    requestAnimationFrame(render);
  }

  render();
}

function startFallback(target) {
  const context = target.getContext("2d");
  if (!context) return;

  const particles = Array.from({ length: 360 }, () => ({
    a: Math.random() * Math.PI * 2,
    b: Math.random() * Math.PI,
    r: 0.28 + Math.random() * 0.38,
    c: Math.random() > 0.65 ? "#ff70ce" : "#b8c8ff",
  }));

  function resize() {
    const rect = target.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    target.width = Math.max(1, Math.round(rect.width * dpr));
    target.height = Math.max(1, Math.round(rect.height * dpr));
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function render(time = 0) {
    const width = target.clientWidth;
    const height = target.clientHeight;
    const cx = width * 0.5;
    const cy = height * 0.48;
    const size = Math.min(width, height) * 0.34;

    context.clearRect(0, 0, width, height);
    for (const p of particles) {
      const a = p.a + time * 0.00018;
      const x = cx + Math.cos(a) * Math.sin(p.b) * size;
      const y = cy + Math.cos(p.b) * size;
      const alpha = 0.24 + Math.sin(a) * 0.22;
      context.globalAlpha = Math.max(0.08, alpha);
      context.fillStyle = p.c;
      context.beginPath();
      context.arc(x, y, 1.2 + p.r, 0, Math.PI * 2);
      context.fill();
    }
    context.globalAlpha = 1;
    requestAnimationFrame(render);
  }

  window.addEventListener("resize", resize, { passive: true });
  resize();
  render();
}

function initScreenshotSlider() {
  const slider = document.querySelector("[data-gallery-slider]");
  if (!slider) return;

  const viewport = slider.querySelector("[data-slider-viewport]");
  const track = slider.querySelector("[data-slider-track]");
  const slides = [...slider.querySelectorAll(".slide")];
  const dots = [...slider.querySelectorAll("[data-slider-dot]")];
  const previous = slider.querySelector("[data-slider-prev]");
  const next = slider.querySelector("[data-slider-next]");
  if (!viewport || !track || slides.length === 0) return;

  let activeIndex = 0;
  let dragStartX = 0;
  let dragDeltaX = 0;
  let dragging = false;

  function normalize(index) {
    return (index + slides.length) % slides.length;
  }

  function setActive(index, options = {}) {
    activeIndex = normalize(index);
    track.style.transition = options.animate === false ? "none" : "";
    track.style.transform = `translateX(${-activeIndex * 100}%)`;

    slides.forEach((slide, slideIndex) => {
      slide.setAttribute("aria-hidden", slideIndex === activeIndex ? "false" : "true");
    });

    dots.forEach((dot, dotIndex) => {
      if (dotIndex === activeIndex) {
        dot.setAttribute("aria-current", "true");
      } else {
        dot.removeAttribute("aria-current");
      }
    });

    if (options.animate === false) {
      requestAnimationFrame(() => {
        track.style.transition = "";
      });
    }
  }

  function finishDrag() {
    if (!dragging) return;
    dragging = false;
    const threshold = Math.min(130, viewport.clientWidth * 0.18);
    if (dragDeltaX < -threshold) {
      setActive(activeIndex + 1);
    } else if (dragDeltaX > threshold) {
      setActive(activeIndex - 1);
    } else {
      setActive(activeIndex);
    }
    dragDeltaX = 0;
  }

  previous?.addEventListener("click", () => setActive(activeIndex - 1));
  next?.addEventListener("click", () => setActive(activeIndex + 1));

  dots.forEach((dot) => {
    dot.addEventListener("click", () => {
      const index = Number(dot.dataset.sliderDot);
      if (Number.isFinite(index)) setActive(index);
    });
  });

  viewport.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      setActive(activeIndex - 1);
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      setActive(activeIndex + 1);
    }
  });

  viewport.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 && event.pointerType === "mouse") return;
    dragging = true;
    dragStartX = event.clientX;
    dragDeltaX = 0;
    track.style.transition = "none";
    viewport.setPointerCapture?.(event.pointerId);
  });

  viewport.addEventListener("pointermove", (event) => {
    if (!dragging) return;
    dragDeltaX = event.clientX - dragStartX;
    track.style.transform = `translateX(calc(${-activeIndex * 100}% + ${dragDeltaX}px))`;
  });

  viewport.addEventListener("pointerup", finishDrag);
  viewport.addEventListener("pointercancel", finishDrag);
  viewport.addEventListener("lostpointercapture", finishDrag);

  window.addEventListener("resize", () => setActive(activeIndex, { animate: false }), {
    passive: true,
  });

  setActive(0, { animate: false });
}

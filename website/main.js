const revealTargets = document.querySelectorAll("[data-reveal]");

if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.18 }
  );

  revealTargets.forEach((target) => observer.observe(target));
} else {
  revealTargets.forEach((target) => target.classList.add("is-visible"));
}

const bundleTree = document.getElementById("tree");

async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // Fall back for embedded browsers or permission-denied clipboard contexts.
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  const copied = document.execCommand("copy");
  textarea.remove();
  if (!copied) throw new Error("Copy command was not accepted");
}

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const value = button.dataset.copy === "tree" ? bundleTree?.innerText : button.dataset.copy;
    if (!value) return;

    const original = button.textContent;
    try {
      await copyText(value);
      button.textContent = "Copied";
      window.setTimeout(() => {
        button.textContent = original;
      }, 1400);
    } catch {
      const container = button.closest(".bundle-terminal, .command-row");
      const selectable = container?.querySelector("pre, code");
      if (selectable) {
        const range = document.createRange();
        range.selectNodeContents(selectable);
        window.getSelection()?.removeAllRanges();
        window.getSelection()?.addRange(range);
      }
      button.textContent = "Selected";
      window.setTimeout(() => {
        button.textContent = original;
      }, 1400);
    }
  });
});

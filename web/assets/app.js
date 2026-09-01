const MERMAID_MODULE_URL = "https://cdn.jsdelivr.net/npm/mermaid@11.12.0/dist/mermaid.esm.min.mjs";
const PROGRESS_STORAGE_KEY = "mcp-sql-workshop:v1:module-progress";

export function grantUtilization(grantedKb, totalKb) {
  if (
    !Number.isFinite(grantedKb) ||
    !Number.isFinite(totalKb) ||
    totalKb <= 0 ||
    grantedKb < 0 ||
    grantedKb > totalKb
  ) {
    throw new TypeError("Memory values must be finite, nonnegative, and no greater than totalKb; totalKb must be positive.");
  }
  return (grantedKb / totalKb) * 100;
}

export function targetStatus(baseline, optimized) {
  if (
    !Number.isFinite(baseline) ||
    !Number.isFinite(optimized) ||
    baseline < 0 ||
    baseline > 100 ||
    optimized < 0 ||
    optimized > 100
  ) {
    throw new TypeError("Utilization percentages must be finite values from 0 through 100.");
  }

  const baselineMet = baseline >= 75 && baseline <= 85;
  const optimizedMet = optimized >= 35 && optimized <= 45;
  if (baselineMet && optimizedMet) return "TargetMet";
  if (baseline - optimized >= 25) return "ImprovedOutsideTarget";
  return "NoMaterialImprovement";
}

function readProgress() {
  try {
    const value = localStorage.getItem(PROGRESS_STORAGE_KEY);
    if (value === null) return {};
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function writeProgress(progress) {
  try {
    localStorage.setItem(PROGRESS_STORAGE_KEY, JSON.stringify(progress));
    return true;
  } catch {
    return false;
  }
}

function updateProgressControl(button, complete, storageAvailable = true) {
  button.setAttribute("aria-pressed", String(complete));
  button.textContent = complete ? "Module complete" : "Mark module complete";
  const status = button.parentElement?.querySelector("[data-progress-status]");
  if (status) {
    status.textContent = storageAvailable
      ? complete ? "Completed in this browser." : "Progress cleared in this browser."
      : "Progress changed for this page only; browser storage is unavailable.";
  }
}

function initializeProgress() {
  const progress = readProgress();
  document.querySelectorAll("[data-progress-toggle]").forEach((button) => {
    updateProgressControl(button, progress[button.dataset.moduleId] === true);
  });
}

function initializeCopyControls() {
  document.querySelectorAll("pre:not(.mermaid)").forEach((pre, index) => {
    const sourceId = `copy-source-${index + 1}`;
    const statusId = `copy-status-${index + 1}`;
    pre.id = sourceId;

    const wrapper = document.createElement("div");
    wrapper.className = "code-block";
    pre.before(wrapper);
    wrapper.append(pre);

    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy-control";
    button.dataset.copy = sourceId;
    button.setAttribute("aria-describedby", statusId);
    button.textContent = "Copy code";

    const status = document.createElement("span");
    status.id = statusId;
    status.className = "copy-status";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");

    wrapper.append(button, status);
  });
}

async function copyCode(button) {
  const source = document.getElementById(button.dataset.copy);
  const status = document.getElementById(button.getAttribute("aria-describedby"));
  if (!source || !status) return;

  try {
    await navigator.clipboard.writeText(source.textContent ?? "");
    status.textContent = "Code copied to clipboard.";
    button.textContent = "Copied";
  } catch {
    status.textContent = "Clipboard access failed. Select and copy the code manually.";
    button.textContent = "Copy unavailable";
  }
}

function initializeNavigation() {
  const toggle = document.querySelector("[data-nav-toggle]");
  const navigation = document.getElementById(toggle?.getAttribute("aria-controls") ?? "");
  if (!toggle || !navigation) return;

  const setOpen = (open) => {
    toggle.setAttribute("aria-expanded", String(open));
    navigation.dataset.open = String(open);
  };

  toggle.addEventListener("click", () => {
    setOpen(toggle.getAttribute("aria-expanded") !== "true");
  });
  navigation.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      setOpen(false);
      toggle.focus();
    }
  });
}

function initializeSiteSearch() {
  const form = document.querySelector("[data-site-search]");
  const input = form?.querySelector("[data-site-search-input]");
  const status = form?.querySelector("[data-site-search-status]");
  if (!(form instanceof HTMLFormElement) || !(input instanceof HTMLInputElement) || !status) return;

  form.addEventListener("submit", (event) => event.preventDefault());
  input.addEventListener("input", () => {
    const query = input.value.trim().toLocaleLowerCase();
    let visible = 0;
    document.querySelectorAll(".module-navigation .module-node").forEach((node) => {
      const matches = !query || (node.textContent ?? "").toLocaleLowerCase().includes(query);
      node.hidden = !matches;
      if (matches) visible += 1;
    });
    status.textContent = query ? `${visible} pages shown.` : "All pages shown.";
  });
}

function formNumber(form, selector) {
  const control = form.querySelector(selector);
  return control instanceof HTMLInputElement ? control.valueAsNumber : Number.NaN;
}

function initializeGrantCalculator() {
  const form = document.querySelector("[data-grant-calculator]");
  if (!(form instanceof HTMLFormElement)) return;
  const output = form.querySelector("output");

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    if (!form.reportValidity() || !output) return;

    try {
      const baseline = grantUtilization(
        formNumber(form, "#baseline-granted-kb"),
        formNumber(form, "#baseline-total-kb"),
      );
      const optimized = grantUtilization(
        formNumber(form, "#optimized-granted-kb"),
        formNumber(form, "#optimized-total-kb"),
      );
      const status = targetStatus(baseline, optimized);
      output.textContent = `Entered utilization — baseline ${baseline.toFixed(1)}%; optimized ${optimized.toFixed(1)}%. Target-band check: ${status}. This is not a run outcome; correctness and secondary evidence are not evaluated. TARGET bands: 75–85% and 35–45%.`;
      const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      output.scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth", block: "nearest" });
    } catch (error) {
      output.textContent = error instanceof Error ? error.message : "Enter valid memory values.";
    }
  });
}

async function initializeMermaid() {
  if (!document.querySelector(".mermaid")) return;
  try {
    const { default: mermaid } = await import(MERMAID_MODULE_URL);
    const theme = document.documentElement.dataset.theme === "dark" ? "dark" : "default";
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme });
    await mermaid.run({ querySelector: ".mermaid" });
  } catch {
    document.documentElement.dataset.diagramStatus = "unavailable";
  }
}

function initializeWorkbench() {
  document.documentElement.classList.add("js");
  initializeNavigation();
  initializeSiteSearch();
  initializeProgress();
  initializeCopyControls();
  initializeGrantCalculator();
  void initializeMermaid();

  document.addEventListener("click", (event) => {
    if (!(event.target instanceof Element)) return;
    const copyButton = event.target.closest("[data-copy]");
    if (copyButton instanceof HTMLButtonElement) void copyCode(copyButton);

    const progressButton = event.target.closest("[data-progress-toggle]");
    if (progressButton instanceof HTMLButtonElement) {
      const complete = progressButton.getAttribute("aria-pressed") !== "true";
      const progress = readProgress();
      progress[progressButton.dataset.moduleId] = complete;
      updateProgressControl(progressButton, complete, writeProgress(progress));
    }
  });
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initializeWorkbench, { once: true });
  } else {
    initializeWorkbench();
  }
}
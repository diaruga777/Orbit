const themeButton = document.querySelector('.theme-toggle');
const systemTheme = window.matchMedia('(prefers-color-scheme: dark)');
let appearance = null;
try { appearance = localStorage.getItem('orbit-appearance'); } catch { /* Storage is optional. */ }
function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeButton.setAttribute('aria-label', `Switch to ${theme === 'dark' ? 'light' : 'dark'} appearance`);
  document.querySelector('meta[name="theme-color"]').content = theme === 'dark' ? '#14171e' : '#f8f9fc';
}
setTheme(appearance === 'light' || appearance === 'dark' ? appearance : systemTheme.matches ? 'dark' : 'light');
themeButton.addEventListener('click', () => {
  appearance = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  setTheme(appearance);
  try { localStorage.setItem('orbit-appearance', appearance); } catch { /* Storage is optional. */ }
});
systemTheme.addEventListener('change', event => { if (!appearance) setTheme(event.matches ? 'dark' : 'light'); });
const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(tab) {
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
}
for (const tab of tabs) {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', event => {
    const index = tabs.indexOf(tab);
    let next;
    if (event.key === 'ArrowDown') next = tabs[(index + 1) % tabs.length];
    if (event.key === 'ArrowUp') next = tabs[(index - 1 + tabs.length) % tabs.length];
    if (event.key === 'Home') next = tabs[0];
    if (event.key === 'End') next = tabs[tabs.length - 1];
    if (next) { event.preventDefault(); selectTab(next); next.focus(); }
  });
}

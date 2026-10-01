// [Co-developed with claude code -- Adam]
// Web-GUI's shape (tailwind.config.js @ f63a55ce): theme.extend {} and no custom theme keys; colours
// are arbitrary values in the class names (text-[#1976d2]), so the classes move into Web-GUI as they
// are. `content` names only this app's own files: its src, and the one class list the manual uses;
// `relative` resolves them against this file, not against whichever directory the build runs from.
/** @type {import('tailwindcss').Config} */
export default {
  content: {
    relative: true,
    files: ['./index.html', './src/**/*.{ts,tsx}', './manual/style.json'],
  },
  theme: {
    extend: {},
  },
  plugins: [],
};

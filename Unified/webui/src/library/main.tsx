import { render } from 'preact';
import '../shared/tokens.css';
import './library.css';
import { LibraryApp } from './App';
import { applyTheme, themeFromQuery } from './theme';

// The host's Space palette (?bg=&fg=&accent=&surface=&mode=) before first paint.
applyTheme(themeFromQuery());

const root = document.getElementById('app');
if (root) {
  render(<LibraryApp />, root);
}

import { render } from 'preact';
import '../shared/tokens.css';
import './settings.css';
import { SettingsApp } from './App';

const root = document.getElementById('app');
if (root) {
  render(<SettingsApp />, root);
}

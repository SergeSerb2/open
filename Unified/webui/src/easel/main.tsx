import { render } from 'preact';
import '../shared/tokens.css';
import './easel.css';
import { EaselApp } from './App';

const root = document.getElementById('app');
if (root) {
  render(<EaselApp />, root);
}

import { render } from 'preact';
import '../shared/tokens.css';
import './boosts.css';
import { BoostsApp } from './App';

const root = document.getElementById('app');
if (root) {
  render(<BoostsApp />, root);
}

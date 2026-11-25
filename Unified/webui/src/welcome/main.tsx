import { render } from 'preact';
import '../shared/tokens.css';
import './welcome.css';
import { WelcomeApp } from './App';

const root = document.getElementById('app');
if (root) {
  render(<WelcomeApp />, root);
}

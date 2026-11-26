import { render } from 'preact';
import '../shared/tokens.css';
import './art.css';
import './onboarding.css';
import { OnboardingApp } from './App';

const root = document.getElementById('app');
if (root) {
  render(<OnboardingApp />, root);
}

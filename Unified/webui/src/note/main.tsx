import { render } from 'preact';
import '../shared/tokens.css';
import './note.css';
import { NoteApp } from './App';

const root = document.getElementById('app');
if (root) {
  render(<NoteApp />, root);
}

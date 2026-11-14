import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
// The shared styles first, so the styles of pages and components come later and can refine them.
import './styles/index.css';
import { App } from './app/App';

const container = document.getElementById('root');
if (!container) throw new Error('index.html has no #root element.');

createRoot(container).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

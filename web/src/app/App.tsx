import { ConverterPage } from '../pages/converter/ConverterPage';
import { FoldersPage } from '../pages/folders/FoldersPage';
import { JobPage } from '../pages/jobs/JobPage';
import { JobsPage } from '../pages/jobs/JobsPage';
import { LogPage } from '../pages/log/LogPage';
import { NotFoundPage } from '../pages/NotFoundPage';
import { OverviewPage } from '../pages/overview/OverviewPage';
import { SettingsPage } from '../pages/settings/SettingsPage';
import { WidgetPage } from '../pages/widget/WidgetPage';
import { ApiProvider } from './ApiProvider';
import { Layout } from './Layout';
import { useRoute } from './router';

export function App() {
  return (
    <ApiProvider>
      <AppContent />
    </ApiProvider>
  );
}

/**
 * The page the hash names, in the layout. The widget stands alone, with its own token form,
 * because other dashboards show it in a small frame where a header and navigation do not fit.
 */
export function AppContent() {
  const { page } = useRoute();
  return page === 'widget' ? (
    <CurrentPage />
  ) : (
    <Layout>
      <CurrentPage />
    </Layout>
  );
}

/** The page the hash names. A page with an id or a folder starts afresh when that changes. */
export function CurrentPage() {
  const route = useRoute();
  switch (route.page) {
    case 'overview':
      return <OverviewPage />;
    case 'jobs':
      return <JobsPage state={route.state} />;
    case 'job':
      return <JobPage key={route.id} id={route.id} itemState={route.itemState} />;
    case 'folders':
      return (
        <FoldersPage key={`${route.root ?? ''}/${route.path}`} root={route.root} path={route.path} />
      );
    case 'settings':
      return <SettingsPage />;
    case 'converter':
      return <ConverterPage />;
    case 'log':
      return <LogPage />;
    case 'widget':
      return <WidgetPage theme={route.theme} />;
    case 'not-found':
      return <NotFoundPage path={route.path} />;
  }
}

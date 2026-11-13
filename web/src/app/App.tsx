import { OverviewPage } from '../pages/overview/OverviewPage';
import { ApiProvider } from './ApiProvider';
import { Layout } from './Layout';

export function App() {
  return (
    <ApiProvider>
      <Layout>
        <OverviewPage />
      </Layout>
    </ApiProvider>
  );
}

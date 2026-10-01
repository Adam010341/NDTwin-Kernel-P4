// Copied from Web-GUI (ndtwin-lab/Web-GUI, Apache-2.0) src/components/common/ErrorBoundary.tsx @ f63a55ce7d3a75736e23aca202606f3a1fd447b1.
// License: https://www.apache.org/licenses/LICENSE-2.0 -- see ../../../THIRD_PARTY.md.
// MODIFIED (Apache-2.0 section 4(b)), three changes and nothing else:
//   1. the four English strings go through the string table (i18n.t), as every string of this page does;
//   2. process.env.NODE_ENV === 'development' is import.meta.env.DEV (Vite's; this build has no @types/node);
//   3. the i18n import below.
// [Co-developed with claude code -- Adam]
import React, { Component } from 'react';
import type { ErrorInfo, ReactNode } from 'react';
import i18n from '../../i18n';

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
  onError?: (error: Error, errorInfo: ErrorInfo) => void;
}

interface State {
  hasError: boolean;
  error?: Error;
}

class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error('ErrorBoundary caught an error:', error, errorInfo);
    this.props.onError?.(error, errorInfo);
  }

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) {
        return this.props.fallback;
      }

      return (
        <div className="flex min-h-screen flex-col items-center justify-center bg-gray-50">
          <div className="rounded-lg bg-white p-8 text-center shadow-md">
            <div className="mb-4 text-6xl text-red-500">⚠️</div>
            <h1 className="mb-4 text-2xl font-bold text-gray-800">
              {i18n.t('ndtServe.err.boundaryTitle')}
            </h1>
            <p className="mb-6 text-gray-600">
              {i18n.t('ndtServe.err.boundaryBody')}
            </p>
            <button
              onClick={() => window.location.reload()}
              className="rounded bg-blue-600 px-4 py-2 text-white transition-colors hover:bg-blue-700"
            >
              {i18n.t('ndtServe.err.boundaryReload')}
            </button>
            {import.meta.env.DEV && this.state.error && (
              <details className="mt-4 text-left">
                <summary className="cursor-pointer text-sm text-gray-500">
                  {i18n.t('ndtServe.err.boundaryDetails')}
                </summary>
                <pre className="mt-2 overflow-auto rounded bg-gray-100 p-2 text-xs">
                  {this.state.error.stack}
                </pre>
              </details>
            )}
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;

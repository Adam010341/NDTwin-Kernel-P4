// Copied from Web-GUI (ndtwin-lab/Web-GUI, Apache-2.0) src/components/common/LoadingSpinner.tsx @ f63a55ce7d3a75736e23aca202606f3a1fd447b1,
// unchanged below this header. License: https://www.apache.org/licenses/LICENSE-2.0 -- see ../../../THIRD_PARTY.md.
// [Co-developed with claude code -- Adam]
import React from 'react';

interface LoadingSpinnerProps {
  size?: 'small' | 'medium' | 'large';
  color?: string;
  text?: string;
  className?: string;
}

const LoadingSpinner: React.FC<LoadingSpinnerProps> = ({
  size = 'medium',
  color = 'text-blue-600',
  text,
  className = '',
}) => {
  const sizeClasses = {
    small: 'w-4 h-4',
    medium: 'w-8 h-8',
    large: 'w-12 h-12',
  };

  return (
    <div className={`flex flex-col items-center justify-center ${className}`}>
      <div
        className={`${sizeClasses[size]} ${color} animate-spin rounded-full border-2 border-gray-300 border-t-current`}
      />
      {text && <p className="mt-2 text-sm text-gray-600">{text}</p>}
    </div>
  );
};

export default LoadingSpinner;

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  webpack: (config, { isServer }) => {
    if (!isServer) {
      // Ensure matrix-js-sdk is only bundled for client-side
      config.resolve.fallback = {
        ...config.resolve.fallback,
        fs: false,
        net: false,
        tls: false,
      };
      
      // Prevent multiple entrypoints for matrix-js-sdk
      config.resolve.alias = {
        ...config.resolve.alias,
        'matrix-js-sdk': require.resolve('matrix-js-sdk'),
      };
    }
    return config;
  },
}

module.exports = nextConfig


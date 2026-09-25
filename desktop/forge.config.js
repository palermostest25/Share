module.exports = {
  packagerConfig: {
    asar: true,
    executableName: 'Share',
    appBundleId: 'dev.denby.share.desktop'
  },
  makers: [
    { name: '@electron-forge/maker-squirrel', platforms: ['win32'], config: { name: 'Share' } },
    { name: '@electron-forge/maker-deb', platforms: ['linux'], config: { options: { bin: 'Share', maintainer: 'Share', homepage: 'https://github.com/palermostest25/Share' } } },
    { name: '@electron-forge/maker-rpm', platforms: ['linux'], config: { options: { bin: 'Share', homepage: 'https://github.com/palermostest25/Share' } } },
    { name: '@electron-forge/maker-zip', platforms: ['win32', 'linux'] }
  ]
};

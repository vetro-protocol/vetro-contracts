// Minimal ABIs shared by tasks, readable through any Vetro implementation version

export const TREASURY_ABI = [
  'function NAME() view returns (string)',
  'function gateway() view returns (address)',
  'function swapper() view returns (address)',
  'function priceTolerance() view returns (uint256)',
  'function defaultAdmin() view returns (address)',
  'function whitelistedTokens() view returns (address[])',
  'function tokenConfig(address) view returns (address vault, address oracle, uint256 stalePeriod, bool depositActive, bool withdrawActive, uint8 decimals)',
  'function hasRole(bytes32,address) view returns (bool)',
  'function KEEPER_ROLE() view returns (bytes32)',
  'function UMM_ROLE() view returns (bytes32)',
  'function MAINTAINER_ROLE() view returns (bytes32)',
  'function reserve() view returns (uint256)',
  'function withdrawable(address) view returns (uint256)',
  'function getPrice(address) view returns (uint256 latestPrice, uint256 unitPrice)',
]

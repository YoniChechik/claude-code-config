// Jest setup file

// Ensure NODE_ENV is set to 'test' for React development builds
process.env.NODE_ENV = "test";

import "@testing-library/jest-dom";

// Mock scrollIntoView for JSDOM (only if Element exists)
if (typeof Element !== "undefined") {
  Element.prototype.scrollIntoView = jest.fn();
}

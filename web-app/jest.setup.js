// Jest setup file
import "@testing-library/jest-dom";
import * as React from "react";

// Fix React 19 + @testing-library/react compatibility
// The issue is that react-dom/test-utils looks for React.act
// In React 19, act is only exported from 'react', not attached to the React object
global.React = React;

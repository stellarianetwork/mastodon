import React, { Fragment } from 'react';
import { FormattedNumber } from 'react-intl';

export const shortNumberFormat = number => {
  return <FormattedNumber value={number} />;
};

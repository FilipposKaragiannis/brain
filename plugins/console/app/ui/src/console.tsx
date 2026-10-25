import { createContext, useContext } from 'react';
import type { ReactNode } from 'react';
import type { Api } from './api.ts';
import type { StreamHub } from './stream.ts';

export type ConsoleServices = { api: Api; hub: StreamHub };

const ServicesContext = createContext<ConsoleServices | null>(null);

export function ServicesProvider({ services, children }: { services: ConsoleServices; children: ReactNode }) {
  return <ServicesContext.Provider value={services}>{children}</ServicesContext.Provider>;
}

export function useServices(): ConsoleServices {
  const services = useContext(ServicesContext);
  if (services === null) throw new Error('useServices needs a ServicesProvider above it');
  return services;
}

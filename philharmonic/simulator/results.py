"""A collection of helper functions for generating the results of the
simulation.

"""

import pickle
from datetime import datetime
import pprint

import pandas as pd
import matplotlib.pyplot as plt

from philharmonic import conf
import philharmonic as ph
from philharmonic.logger import *
from philharmonic.scheduler import evaluator
from philharmonic.utils import loc, common_loc

def pickle_results(schedule):
    schedule.actions.to_pickle(loc('schedule.pkl'))

def generate_series_results(cloud, env, schedule, nplots):
    info('Dynamic results\n---------------')
    # cloud utilisation
    #------------------
    # evaluator.precreate_synth_power(env.start, env.end, cloud.servers)
    util = evaluator.calculate_cloud_utilisation(cloud, env, schedule)
    info('Utilisation (%)')
    info(str(util * 100))
    #print('- weighted mean per no')
    # weighted_mean(util[util>0])
    #util[util>0].mean().dropna().mean() * 100
    # TODO: maybe weighted mean for non-zero util
    # ax = plt.subplot(nplots, 1, 1)
    # ax.set_title('Utilisation (%)')
    # util.plot(ax=ax)

    # cloud power consumption
    #------------------
    power = evaluator.generate_cloud_power(util)
    if conf.save_power:
        power.to_pickle(loc('power.pkl'))
    ax = plt.subplot(nplots, 1, 3)
    ax.set_title('Computational power (W)')
    power.plot(ax=ax)
    energy = ph.joul2kwh(ph.calculate_energy(power))
    info('\nEnergy (kWh)')
    info(energy)
    info(' - total:')
    info(energy.sum())

    # cooling overhead
    #-----------------
    #temperature = inputgen.simple_temperature()
    power_total = evaluator.calculate_cloud_cooling(power, env.temperature)
    ax = plt.subplot(nplots, 1, 4)
    ax.set_title('Total power (W)')
    power_total.plot(ax=ax)
    if conf.save_power:
        power_total.to_pickle(loc('power_total.pkl'))
    energy_total = ph.joul2kwh(ph.calculate_energy(power_total))
    info('\nEnergy with cooling (kWh)')
    info(energy_total)
    info(' - total:')
    info(energy_total.sum())

    # pm frequencies
    info('\nPM frequencies')
    pm_freqs = evaluator.calculate_cloud_frequencies(cloud, env, schedule)
    info(pm_freqs)

def serialise_results(cloud, env, schedule):
    fig = plt.figure(1)#, figsize=(10, 15))
    fig.subplots_adjust(bottom=0.2, top=0.9, hspace=0.5)

    nplots = 4
    pickle_results(schedule)
    cloud.reset_to_initial()
    info('Simulation timeline\n-------------------')
    evaluator.print_history(cloud, env, schedule)

    # geotemporal inputs
    #-------------------
    ax = plt.subplot(nplots, 1, 1)
    ax.set_title('Electricity prices ($/kWh)')
    env.el_prices.plot(ax=ax)
    ax = plt.subplot(nplots, 1, 2)
    ax.set_title('Temperature (C)')
    env.temperature.plot(ax=ax)

    # dynamic results
    #----------------
    generate_series_results(cloud, env, schedule, nplots)

    energy = -1
    energy_total = -1

    # Aggregated results
    #===================
    info('\nAggregated results\n------------------')

    # migration overhead
    #-------------------
    migration_energy, migration_cost = evaluator.calculate_migration_overhead(
        cloud, env, schedule
    )
    info('Migration energy (kWh)')
    info(migration_energy)
    info(' - total with migrations:')
    info(energy_total + migration_energy)
    info('\nMigration cost ($)')
    info(migration_cost)

    # electricity costs
    #------------------
    # TODO: update the dynamic cost calculations to work on the new power model
    # TODO: reenable
    # en_cost_IT = evaluator.calculate_cloud_cost(power, env.el_prices)
    info('\nElectricity costs ($)')
    # info(' - electricity cost without cooling:')
    # info(en_cost_IT)
    info(' - total electricity cost without cooling:')
    en_cost_IT_total = evaluator.combined_cost(cloud, env, schedule,
                                               env.el_prices)
    info(en_cost_IT_total)

    # TODO: reenable
    # en_cost_with_cooling = evaluator.calculate_cloud_cost(power_total,
    #                                                       env.el_prices)
    # info(' - electricity cost with cooling:')
    # info(en_cost_with_cooling)
    info(' - total electricity cost with cooling:')
    en_cost_with_cooling_total = evaluator.combined_cost(cloud, env, schedule,
                                                         env.el_prices,
                                                         env.temperature)
    info(en_cost_with_cooling_total)
    info(' - total electricity cost with migrations:')
    en_cost_combined = en_cost_with_cooling_total + migration_cost
    info(en_cost_combined)
    # QoS aspects
    info(' - total profit from users')
    serv_profit = evaluator.calculate_service_profit(cloud, env, schedule)
    info(serv_profit)

    #------------------
    # Capacity constraints
    #---------------------
    # TODO: these two

    # aggregated results
    aggregated = [energy, en_cost_IT_total,
                  energy_total + migration_energy,
                  en_cost_combined]
    aggr_names = ['IT energy (kWh)', 'IT cost ($)',
                  'Total energy (kWh)', 'Total cost ($)']
    aggregated_results = pd.Series(aggregated, aggr_names)
    aggregated_results.to_pickle(loc('results.pkl'))
    #aggregated_results.plot(kind='bar')
    info(aggregated_results)

    if conf.liveplot:
        plt.show()
    elif conf.liveplot:
        plt.savefig(loc('results-graph.pdf'))

    info('\nDone. Results saved to: {}'.format(conf.output_folder))

    return aggregated_results

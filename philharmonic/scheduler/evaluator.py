"""Evaluates a simulation, based on the cloud, environment and the actually
performed schedule of actions

"""

import pandas as pd
import numpy as np

import philharmonic as ph

def print_history(cloud, environment, schedule):
    for t in environment.itertimes():
        requests = environment.get_requests()
        period = environment.get_period()
        actions = schedule.filter_current_actions(t, period)

        print('---t={}----'.format(t))
        if len(requests) > 0:
            print(" - requests:")
            print("    {}".format(str(requests.values)))
        if len(actions) > 0:
            print(" - actions:")
            print("    {}".format(str(actions.values)))
            print('')

def calculate_cloud_utilisation(cloud, environment, schedule):
    """Calculate utilisations of all servers based on the given schedule"""
    cloud.reset_to_initial()
    #TODO: maybe move some of this state iteration functionality into Cloud
    #TODO: check when to add start and end (not always necessary) !!!
    utilisations = {server : [0.0] for server in cloud.servers}
    times = []
    for t in schedule.actions.index.unique():
        # TODO: precise indexing, not dict
        if isinstance(schedule.actions[t], pd.Series):
            for action in schedule.actions[t].values:
                cloud.apply(action)
        else:
            action = schedule.actions[t]
            cloud.apply(action)
        state = cloud.get_current()
        new_utilisations = state.calculate_utilisations()
        times.append(t)
        for server, utilisation in new_utilisations.iteritems():
            utilisations[server].append(utilisation)
    # the last utilisation values hold until the end - duplicate last value
    for server, utilisation in new_utilisations.iteritems():
        utilisations[server].append(utilisation)

    times = [environment.start] + times + [environment.end]

    df_util = pd.DataFrame(utilisations, index=times)
    #df_all = df_util.join(schedule.actions)
    return df_util

def generate_cloud_power(util):
    """Create power signals from varying utilisation rates."""
    P_peak = 200
    P_idle = 100
    P_delta = P_peak - P_idle
    P_std = 1.26 # P_delta * 0.05
    power_freq = '5min'

    power = pd.DataFrame()
    for server in util.columns:
        start = util.index[0]
        end = util.index[-1]
        index = pd.date_range(start, end, freq=power_freq)
        synth_data = P_delta + P_std * np.random.randn(len(index))
        P_synth = pd.TimeSeries(data=synth_data, index=index)

        server_util = util[server]
        server_util = server_util.reindex(index, method='pad')

        power[server] = P_synth * server_util
    power[power>0] += P_idle # a server with no load is suspended
    return power

def calculate_cloud_cost(power, el_prices):
    """Take power and el. prices DataFrames & calc. the el. cost"""
    el_prices_loc = pd.DataFrame()
    for server in power.columns: # this might be very inefficient
        loc = server.loc
        el_prices_loc[server] = el_prices[loc]
    cost = ph.calculate_price(power, el_prices_loc)
    return cost

def calculate_cloud_cooling(power, temperature):
    """Take power and temperature DataFrames & calculate the power with
    cooling overhead.

    """
    temperature_server = pd.DataFrame()
    for server in power.columns: # this might be very inefficient
        loc = server.loc
        temperature_server[server] = temperature[loc]
    #cost = ph.calculate_price(power, el_prices_loc)
    power_with_cooling = ph.calculate_cooling_overhead(power, temperature_server)
    return power_with_cooling

<?php

namespace App\Plugins\SystemChecks\Checks;

use App\Plugins\SystemChecks\Check;
use GuzzleHttp\Client;
use Illuminate\Support\Facades\File;

class NethermindSyncCheck implements Check
{
    public function getId()
    {
        return 'nethermind-sync';
    }

    public function run()
    {
        $result = ['success' => false, 'message' => ''];
        $path = base_path('../veriscope_ta_node/.env');

        try {
        // Check if the .env file exists
        if (!File::exists($path)) {
            $result['message'] = 'Environment file not found';
        }
        // Read the TRUST_ANCHOR_ACCOUNT variable from the .env file
        $envContents = File::get($path);
        preg_match('/HTTP=(.+)/', $envContents, $matches);
        // Get Web3 HTTP RPC endpointName
        $httpRpc = str_replace('"', '',$matches[1]) ?? null;
        // Check if the HTTP variable is set
        if ($httpRpc  === null) {
            $result['message'] =  'HTTP is not set';
            return $result;
        }



        $client = new Client(['base_uri' => $httpRpc]);

        // Check sync status
        $response = $client->post('', ['json' => [
            'jsonrpc' => '2.0',
            'method' => 'eth_syncing',
            'params' => [],
            'id' => 1,
        ]]);
        $body = json_decode($response->getBody(), true);
        $syncStatus = $body['result'];

        // eth_syncing returns false when fully synced, or an object with sync progress when syncing
        if ($syncStatus === false) {
            // Check peer count to ensure we're connected to the network
            $response = $client->post('', ['json' => [
                'jsonrpc' => '2.0',
                'method' => 'net_peerCount',
                'params' => [],
                'id' => 2,
            ]]);
            $body = json_decode($response->getBody(), true);
            $peerCount = hexdec($body['result']);

            if ($peerCount === 0) {
                $result['message'] = 'Nethermind has no peers connected. Cannot verify sync status.';
                return $result;
            }

            $result['success'] = true;
            $result['message'] = 'Nethermind is fully synced with ' . $peerCount . ' peer(s)';
            return $result;
        } else {
            // Currently syncing
            $currentBlock = hexdec($syncStatus['currentBlock']);
            $highestBlock = hexdec($syncStatus['highestBlock']);
            $result['message'] = 'Nethermind is syncing. Current block: ' . $currentBlock . ', Highest block: ' . $highestBlock;
            return $result;
        }



      } catch (\Exception $e) {
        $result['message'] = 'Nethermind is not running due to error: '. $e->getMessage();
        return $result;
       }


    }
}

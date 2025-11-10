<?php

namespace App\Plugins\SystemChecks\Checks;

use App\Plugins\SystemChecks\Check;
use Illuminate\Support\Facades\Artisan;
use Symfony\Component\Process\Exception\ProcessFailedException;
use Symfony\Component\Process\Process;

class HorizonCheck implements Check
{
    public function getId()
    {
        return 'horizon';
    }

    public function run()
    {
        $result = ['success' => false, 'message' => ''];

        try {
            // Check Horizon status via artisan command
            Artisan::call('horizon:status');
            $output = Artisan::output();

            // If Horizon is running, the output will contain "running"
            if (stripos($output, 'running') !== false) {
                $result['success'] = true;
                $result['message'] = 'Horizon is running';
            } else {
                $result['message'] = 'Horizon is not running';
            }

            return $result;
        } catch (\Exception $e) {
            $result['message'] = 'Unable to check Horizon status: ' . $e->getMessage();
            return $result;
        }
    }
}

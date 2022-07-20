## prerequisites - DATABRICKS_HOST and DATABRICKS_TOKEN env variables should be set

## inital version of determining business hours and nodes configured. It works only on schedules start date, have to extend it to work on days between start & end times.
current_day=`echo "$(date +%A)"`
current_hour=`echo "$(date +%H)"`
echo "current day and hour = ${current_day}, ${current_hour}"
## collecting business and non business hour properties
businesshours_start_day=`cat settings.json | jq ".schedules | .business_hours | .start_time | .day // empty" | tr -d '"'`
businesshours_start_hour=`cat settings.json | jq ".schedules | .business_hours | .start_time | .hour // empty" | tr -d '"'`
nonbusinesshours_start_day=`cat settings.json | jq ".schedules | .nonbusiness_hours | .start_time | .day // empty" | tr -d '"'`
nonbusinesshours_start_hour=`cat settings.json | jq ".schedules | .nonbusiness_hours | .start_time | .hour // empty" | tr -d '"'`
echo "businesshours_start_day=${businesshours_start_day}, businesshours_start_hour=${businesshours_start_hour}"
echo "nonbusinesshours_start_day=${nonbusinesshours_start_day}, nonbusinesshours_start_hour=${nonbusinesshours_start_hour}"
## determining business hour tag
if [[ ($current_day == $businesshours_start_day) && ($current_hour -ge $businesshours_start_hour) ]]; then
  business_hour_tag="business_hours"
elif [[ ($current_day == $nonbusinesshours_start_day) && ($current_hour -ge $nonbusinesshours_start_hour) ]]; then
  business_hour_tag="nonbusiness_hours"
else
  business_hour_tag="business_hours"
fi
echo "business_hour_tag=${business_hour_tag}"

## collecting instance pool's properties from setting.json relevant to the environment
echo "fetching instance pool details configured for ${env_name} env from settings.json"
instance_pool_name=`cat settings.json | jq ".deployment | .db_instance_pool | .instance_pool_name // empty" | tr -d '"'`
node_type_id=`cat settings.json | jq ".deployment | .db_instance_pool | .node_type_id // empty" | tr -d '"'`
max_capacity=`cat settings.json | jq ".deployment | .db_instance_pool | .max_capacity // empty" | tr -d '"'`
min_idle_nodes=`cat settings.json | jq ".deployment | .db_instance_pool | .${business_hour_tag} | .min_idle_instances // empty" | tr -d '"'`
idle_temination_mins=`cat settings.json | jq ".deployment | .db_instance_pool | .idle_instance_autotermination_minutes // empty" | tr -d '"'`
preloaded_spark_version=`cat settings.json | jq ".deployment | .db_instance_pool | .preloaded_spark_versions // empty" | tr -d '"'`

echo "instance_pool_name=${instance_pool_name}"
echo "node_type_id=${node_type_id}"
echo "max_capacity=${max_capacity}"
echo "min_idle_nodes=${min_idle_nodes}"
echo "idle_temination_mins=${idle_temination_mins}"
echo "preloaded_spark_version=${preloaded_spark_version}"

## preparing the temporary file names going to be used
current_time=`echo "$(date +%s)"`
current_deploy_file=`echo "instancepool_template_${current_time}.json"`
current_deploy_tmp_file=`echo "instancepool_template_${current_time}_tmp.json"`
current_deploy_edit_file=`echo "instancepool_template_${current_time}_edit.json"`


## creating the instance pool creation json file using the values from settings.json
echo "creating the instance pool creation json file using the values from settings.json"

# preparing the node_type_id
jq --arg node_type_id ${node_type_id} '.node_type_id=$node_type_id' instancepool_template.json > $current_deploy_file

# preparing the min_idle_nodes
jq --arg min_idle_nodes ${min_idle_nodes} '.min_idle_instances=($min_idle_nodes|tonumber)' $current_deploy_file > $current_deploy_tmp_file
cat $current_deploy_tmp_file > $current_deploy_file

# preparing the max_capacity
jq --arg max_capacity ${max_capacity} '.max_capacity=($max_capacity|tonumber)' $current_deploy_file > $current_deploy_tmp_file
cat $current_deploy_tmp_file > $current_deploy_file

# preparing the idle_temination_mins
jq --arg idle_temination_mins ${idle_temination_mins} '.idle_instance_autotermination_minutes=($idle_temination_mins|tonumber)' $current_deploy_file > $current_deploy_tmp_file
cat $current_deploy_tmp_file > $current_deploy_file

# preparing the preloaded_spark_version
jq --arg preloaded_spark_version ${preloaded_spark_version} '.preloaded_spark_versions=$preloaded_spark_version' $current_deploy_file > $current_deploy_tmp_file
cat $current_deploy_tmp_file > $current_deploy_file

## applying instance-pool creation command using the json prepared
 echo "applying instance-pool creation command using the json prepared"
 response=`databricks instance-pools create --json-file  $current_deploy_file`

 echo "instance pool creation response = ${response}, parsing the instance pool id..."
 instance_pool_id=`echo "${response}" | jq -r '.instance_pool_id'`

 # successful exit upon pool creation
 if [ $? -eq 0 ]; then
   echo "instance pool was successfully created with id ${instance_pool_id}"
   exit 0
 # checking if pool exits, if not exit with fail staus
 elif [[ $response == *"already exists"* ]]; then
   echo "instance pool ${instance_pool_name} already exists, updating its properties..."

   instance_pool_id=`databricks instance-pools list | grep ${instance_pool_name} | cut -d' ' -f1 | tr -d '[:space:]'`
   echo "instance pool ${instance_pool_name}'s id is ${instance_pool_id}"

   # updating exitsting pool's properties read from settings.json
   update_payload=`echo '{"instance_pool_id": "'"${instance_pool_id}"'", "instance_pool_name": "'"${instance_pool_name}"'", "node_type_id": "'"${node_type_id}"'", "min_idle_instances": '${min_idle_nodes}', "max_capacity": '${max_capacity}', "idle_instance_autotermination_minutes": '${idle_temination_mins}'}'`
   echo "instance pool update payload = ${update_payload}"
   echo "${update_payload}" > $current_deploy_edit_file

   # applying instance-pool update command using the json prepared
   echo "applying instance-pool update command using the json prepared"
   edit_response=`databricks instance-pools edit --json-file ${current_deploy_edit_file}`

   if [ $? -eq 0 ]; then
     # successful exit upon pool updation
     if [ -z $edit_response]; then
       echo "successfully updated the instance-pool ${instance_pool_name}'s properties."
       exit 0
     else
       # exit with failure code if non-empty response if found
       echo "failed to update the instance-pool ${instance_pool_name}'s properties."
       echo "update response = ${edit_response}"
       exit 1
     fi
   else
     # exit with failure code if non-empty response if found
     echo "failed to update the instance-pool ${instance_pool_name}'s properties."
     echo "update response = ${edit_response}"
     exit 1
   fi
 else
   # exit with failure code if unexpected reponse was received
   echo "failed to update the instance-pool ${instance_pool_name}'s properties."
   echo "update response = ${edit_response}"
   exit 1
 fi

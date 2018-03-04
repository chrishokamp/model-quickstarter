#!/bin/bash
#+------------------------------------------------------------------------------------------------------------------------------+
#| DBpedia Spotlight - Create database-backed model                                                                             |
#| @author Joachim Daiber                                                                                                       |
#+------------------------------------------------------------------------------------------------------------------------------+

# $1 Working directory
# $2 Locale (en_US)
# $3 Stopwords file
# $4 Analyzer+Stemmer language prefix e.g. Dutch
# $5 Model target folder

export MAVEN_OPTS="-Xmx26G"

usage ()
{
  echo "index_db.sh"
  echo "usage: ./index_db.sh -o /data/spotlight/nl/opennlp wdir nl_NL /data/spotlight/nl/stopwords.nl.list Dutch /data/spotlight/nl/final_model"
  echo "Create a database-backed model of DBpedia Spotlight for a specified language."
  echo " "
}


opennlp="None"
eval="false"
blacklist="false"

while getopts "eo:b:" opt; do
  case $opt in
    o) opennlp="$OPTARG";;
    e) eval="true";;
    b) blacklist="$OPTARG";;
  esac
done


shift $((OPTIND - 1))

if [ $# != 5 ]
then
    usage
    exit
fi

BASE_DIR=$(pwd)

function get_path {
  if [[ "$1"  = /* ]]
  then
    echo "$1"
  else
   echo "$BASE_DIR/$1"
  fi
}

BASE_WDIR=$(get_path $1)
TARGET_DIR=$(get_path $5)
STOPWORDS=$(get_path $3)
WDIR="$BASE_WDIR/$2"

if [[ "$opennlp" != "None" ]]; then
  opennlp=$(get_path $opennlp)
fi
if [[ "$blacklist" != "false" ]]; then
  blacklist=$(get_path $blacklist)
fi

LANGUAGE=`echo $2 | sed "s/_.*//g"`

echo "Language: $LANGUAGE"
echo "Working directory: $WDIR"

mkdir -p $WDIR

########################################################################################################
# Preparing the data.
########################################################################################################

echo "Loading Wikipedia dump..."
if [ -z "$WIKI_MIRROR" ]; then
  WIKI_MIRROR="https://dumps.wikimedia.org/"
fi

WP_DOWNLOAD_FILE=$WDIR/dump.xml
echo Downloading wikipedia dump.
if [ "$eval" == "false" ]; then
  curl -# "$WIKI_MIRROR/${LANGUAGE}wiki/latest/${LANGUAGE}wiki-latest-pages-articles.xml.bz2" | bzcat > $WDIR/dump.xml
else
  curl -# "$WIKI_MIRROR/${LANGUAGE}wiki/latest/${LANGUAGE}wiki-latest-pages-articles.xml.bz2" | bzcat | python $BASE_DIR/scripts/split_train_test.py 1200 $WDIR/heldout.txt > $WDIR/dump.xml
fi

cd $WDIR
cp $STOPWORDS stopwords.$LANGUAGE.list

if [ -e "$opennlp/$LANGUAGE-token.bin" ]; then
  cp "$opennlp/$LANGUAGE-token.bin" "$LANGUAGE.tokenizer_model" || echo "tokenizer already exists"
else
  touch "$LANGUAGE.tokenizer_model"
fi


########################################################################################################
# DBpedia extraction:
########################################################################################################

echo "Creating DBpedia nt files..."
cd $BASE_WDIR

rm -rf extraction-framework
echo "Setting up DEF..."
git clone git://github.com/dbpedia/extraction-framework.git
cd extraction-framework
# 2018-01-08
git checkout 10d102decb6dc4e86bfb3af9eae6d524f743c7a2
# copy our version of universal.properties
cp $BASE_WDIR/universal.properties  core/src/main/resources/universal.properties
mvn install

cd dump

dumpdate=$(date +%Y%m%d)
dumpdir=$WDIR/${LANGUAGE}wiki/${dumpdate}

mkdir -p $dumpdir
ln -s $WDIR/dump.xml $dumpdir/${LANGUAGE}wiki-${dumpdate}-dump.xml

cat << EOF > dbpedia.properties
base-dir=$WDIR
source=dump.xml
require-download-complete=false
languages=$LANGUAGE
ontology=../ontology.xml
mappings=../mappings
uri-policy.uri=uri:en; generic:en; xml-safe-predicates:*
format.nt.gz=n-triples;uri-policy.uri
compareDatasetIDs=false
EOF

if [[ ",ga,ar,be,bg,bn,ced,cs,cy,da,eo,et,fa,fi,gl,hi,hr,hu,id,ja,lt,lv,mk,mt,sk,sl,sr,tr,ur,vi,war,zh," == *",$LANGUAGE,"* ]]; then #Languages with no disambiguation definitions
     echo "extractors=.RedirectExtractor,.MappingExtractor" >> dbpedia.properties
else
     echo "extractors=.RedirectExtractor,.DisambiguationExtractor,.MappingExtractor" >> dbpedia.properties
fi

../run extraction dbpedia.properties

zcat $dumpdir/${LANGUAGE}wiki-${dumpdate}-instance-types*.nt.gz > $WDIR/instance_types.nt
zcat $dumpdir/${LANGUAGE}wiki-${dumpdate}-disambiguations-unredirected.nt.gz > $WDIR/disambiguations.nt
zcat $dumpdir/${LANGUAGE}wiki-${dumpdate}-redirects.nt.gz > $WDIR/redirects.nt

rm -Rf $dumpdir

########################################################################################################
# Setting up Spotlight:
########################################################################################################

cd $BASE_WDIR

rm -rf dbpedia-spotlight
echo "Setting up DBpedia Spotlight..."
git clone --depth 1 https://github.com/dbpedia-spotlight/dbpedia-spotlight-model
mv dbpedia-spotlight-model dbpedia-spotlight
cd dbpedia-spotlight
# 2018-02-18
git checkout d7c153632126d449005c7ca458070e69e1e5baf8
mvn -T 1C -q clean install


########################################################################################################
# Extracting wiki stats:
########################################################################################################

cd $BASE_WDIR
rm -Rf wikistatsextractor
git clone --depth 1 https://github.com/dbpedia-spotlight/wikistatsextractor

# Stop processing if one step fails
set -e

#Copy results to local:
cd $BASE_WDIR/wikistatsextractor
mvn install exec:java -Dexec.args="--output_folder $WDIR $LANGUAGE $2 $4Stemmer $WDIR/dump.xml $WDIR/stopwords.$LANGUAGE.list"

if [ "$blacklist" != "false" ]; then
  echo "Removing blacklist URLs..."
  mv $WDIR/uriCounts $WDIR/uriCounts_all
  grep -v -f $blacklist $WDIR/uriCounts_all > $WDIR/uriCounts
fi


echo "Finished wikistats extraction. Cleaning up..."
rm -f $WDIR/dump.xml


########################################################################################################
# Building Spotlight model:
########################################################################################################

#Create the model:
cd $BASE_WDIR/dbpedia-spotlight

# CHRIS: concat any extra DBPedia type files onto the existing `instance_types.nt` file
# get all of the dbpedia type datasets
wget --directory-prefix=$WDIR \
  -r \
  -nd \
  --no-parent \
  -A 'instance_types_*.ttl.bz2' \
  http://downloads.dbpedia.org/2016-10/core-i18n/$LANGUAGE/

# concat them all together
bzcat $WDIR/*.bz2 >> $WDIR/extra_instance_types.ttl
# now concat the ones we extracted with the dbpedia ones
cat $WDIR/extra_instance_types.ttl $WDIR/instance_types.nt > $WDIR/all_instance_types.nt
# now replace the original instance types file
mv $WDIR/all_instance_types.nt $WDIR/instance_types.nt

# Remove a previous model
echo "If there is an existing model at $TARGET_DIR, I\'m removing it now"
rm -rf $TARGET_DIR
mvn -pl index exec:java -Dexec.mainClass=org.dbpedia.spotlight.db.CreateSpotlightModel -Dexec.args="$2 $WDIR $TARGET_DIR $opennlp $STOPWORDS $4Stemmer"

if [ "$eval" == "true" ]; then
  mvn -pl eval exec:java -Dexec.mainClass=org.dbpedia.spotlight.evaluation.EvaluateSpotlightModel -Dexec.args="$TARGET_DIR $WDIR/heldout.txt" > $TARGET_DIR/evaluation.txt
fi

curl https://raw.githubusercontent.com/dbpedia-spotlight/model-quickstarter/master/model_readme.txt > $TARGET_DIR/README.txt
curl "$WIKI_MIRROR/${LANGUAGE}wiki/latest/${LANGUAGE}wiki-latest-pages-articles.xml.bz2-rss.xml" | grep link | sed -e 's/^.*<link>//' -e 's/<[/]link>.*$//' | uniq >> $TARGET_DIR/README.txt


# Chris: what would we need this for?
#echo "Collecting data..."
#cd $BASE_DIR
#mkdir -p data/$LANGUAGE && mv $WDIR/*Counts data/$LANGUAGE
#gzip $WDIR/*.nt &

set +e
